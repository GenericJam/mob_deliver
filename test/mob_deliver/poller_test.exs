defmodule MobDeliver.PollerTest do
  use ExUnit.Case, async: true

  alias MobDeliver.Poller

  @moduletag :capture_log

  # Starts a poller whose n-th check reports to the test and returns the
  # n-th entry of `results` (a value, or a 0-arity fun to run instead).
  defp start(opts) do
    name = :"poller_#{System.unique_integer([:positive])}"
    test_pid = self()
    results = Keyword.get(opts, :results, [])
    counter = :counters.new(1, [])

    check = fn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:checked, n, System.monotonic_time(:millisecond)})

      case Enum.at(results, n - 1, {:ok, :current}) do
        fun when is_function(fun, 0) -> fun.()
        result -> result
      end
    end

    start_supervised!({Poller, [name: name, check: check] ++ Keyword.drop(opts, [:results])},
      id: name
    )

    Poller.start(name)
    name
  end

  test "checks once at start and then on every interval" do
    start(interval: 20, retry_after: 60_000)

    assert_receive {:checked, 1, _}
    assert_receive {:checked, 2, _}, 500
    assert_receive {:checked, 3, _}, 500
  end

  test "with timed checks off, a deferred check is retried after the stability window" do
    start(interval: false, retry_after: 20, results: [{:ok, :deferred}, {:ok, :installed}])

    assert_receive {:checked, 1, _}
    assert_receive {:checked, 2, _}, 500
    refute_receive {:checked, 3, _}, 100
  end

  test "with timed checks off, nothing runs after the boot check unless deferred" do
    start(interval: false, retry_after: 20, results: [{:error, :offline}])

    assert_receive {:checked, 1, _}
    refute_receive {:checked, 2, _}, 100
  end

  test "repeated deferrals back off exponentially, capped at the poll interval" do
    start(interval: 160, retry_after: 20, results: List.duplicate({:ok, :deferred}, 10))

    times =
      for n <- 1..6 do
        assert_receive {:checked, ^n, at}, 1_000
        at
      end

    gaps = times |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    # 20, 40, 80, then the 160 cap (uncapped: 160, 320).
    for {gap, min} <- Enum.zip(gaps, [20, 40, 80, 160, 160]), do: assert(gap >= min)
    assert Enum.at(gaps, 4) < 320
  end

  test "no timed checks in the background; back in the foreground an overdue check runs at once" do
    poller = start(interval: 300, retry_after: 60_000)
    assert_receive {:checked, 1, _}

    Poller.background(poller)
    # Past the check's due time.
    refute_receive {:checked, _, _}, 450

    # At once, not a fresh interval later.
    Poller.foreground(poller)
    assert_receive {:checked, 2, _}, 150
    assert_receive {:checked, 3, _}, 1_000
  end

  test "background/foreground cycles leave one live timer, not one per cycle" do
    poller = start(interval: 300, retry_after: 60_000)
    assert_receive {:checked, 1, _}
    pid = Process.whereis(poller)
    :erlang.trace(pid, true, [:receive])

    for _ <- 1..5 do
      Poller.background(poller)
      Poller.foreground(poller)
    end

    assert_receive {:checked, 2, _}, 1_000
    Process.sleep(100)
    :erlang.trace(pid, false, [:receive])

    timer_messages =
      Stream.repeatedly(fn ->
        receive do
          {:trace, ^pid, :receive, {:check, _}} -> :timer
          {:trace, ^pid, :receive, _other} -> :other
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.count(&(&1 == :timer))

    assert timer_messages == 1
  end

  test "back in the foreground before a check is due, it runs when due" do
    poller = start(interval: 300, retry_after: 60_000)
    assert_receive {:checked, 1, started}

    Poller.background(poller)
    Poller.foreground(poller)
    refute_receive {:checked, 2, _}, 150
    assert_receive {:checked, 2, at}, 500
    assert at - started >= 300
  end

  test "a crashing check doesn't take the schedule down" do
    poller =
      start(
        interval: 20,
        retry_after: 60_000,
        results: [fn -> raise "boom" end, fn -> exit(:noproc) end]
      )

    pid = Process.whereis(poller)

    assert_receive {:checked, 1, _}
    assert_receive {:checked, 3, _}, 500
    assert Process.whereis(poller) == pid
  end
end
