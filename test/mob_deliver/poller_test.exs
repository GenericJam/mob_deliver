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
      send(test_pid, {:checked, n})

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

    assert_receive {:checked, 1}
    assert_receive {:checked, 2}, 500
    assert_receive {:checked, 3}, 500
  end

  test "with timed checks off, a deferred check is retried after the stability window" do
    start(interval: false, retry_after: 20, results: [{:ok, :deferred}, {:ok, :installed}])

    assert_receive {:checked, 1}
    assert_receive {:checked, 2}, 500
    refute_receive {:checked, 3}, 100
  end

  test "with timed checks off, nothing runs after the boot check unless deferred" do
    start(interval: false, retry_after: 20, results: [{:error, :offline}])

    assert_receive {:checked, 1}
    refute_receive {:checked, 2}, 100
  end

  test "a crashing check doesn't take the schedule down" do
    poller =
      start(
        interval: 20,
        retry_after: 60_000,
        results: [fn -> raise "boom" end, fn -> exit(:noproc) end]
      )

    pid = Process.whereis(poller)

    assert_receive {:checked, 1}
    assert_receive {:checked, 3}, 500
    assert Process.whereis(poller) == pid
  end
end
