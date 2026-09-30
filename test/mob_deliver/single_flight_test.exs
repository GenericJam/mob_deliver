defmodule MobDeliver.SingleFlightTest do
  use ExUnit.Case, async: true

  alias MobDeliver.SingleFlight

  setup do
    name = :"single_flight_#{System.unique_integer([:positive])}"
    start_supervised!({SingleFlight, name: name})
    %{sf: name}
  end

  # A fun that counts its executions and blocks until released, so callers
  # provably overlap.
  defp gated_fun(counter, gate) do
    fn ->
      :counters.add(counter, 1, 1)
      receive_release(gate)
    end
  end

  defp receive_release(gate) do
    ref = Process.monitor(gate)
    send(gate, {:waiting, self()})

    receive do
      {:release, value} -> value
      {:DOWN, ^ref, _, _, _} -> :gate_gone
    end
  end

  defp start_gate do
    spawn_link(fn ->
      receive do
        {:waiting, runner} ->
          receive do
            {:open, value} -> send(runner, {:release, value})
          end
      end
    end)
  end

  # Barrier: returns once `n` callers are registered as waiting on `key`.
  defp await_waiters(sf, key, n, attempts \\ 1_000) do
    waiting = sf |> :sys.get_state() |> get_in([:waiting, key]) |> List.wrap() |> length()

    cond do
      waiting >= n -> :ok
      attempts == 0 -> flunk("only #{waiting}/#{n} callers registered for #{inspect(key)}")
      true -> Process.sleep(1) && await_waiters(sf, key, n, attempts - 1)
    end
  end

  test "concurrent calls for one key run the function once and share its result", %{sf: sf} do
    counter = :counters.new(1, [])
    gate = start_gate()
    fun = gated_fun(counter, gate)

    tasks = for _ <- 1..25, do: Task.async(fn -> SingleFlight.run(sf, :k, fun) end)
    await_waiters(sf, :k, 25)
    send(gate, {:open, {:ok, :shared}})

    assert Enum.map(tasks, &Task.await/1) == List.duplicate({:ok, :shared}, 25)
    assert :counters.get(counter, 1) == 1
  end

  test "different keys run independently", %{sf: sf} do
    assert SingleFlight.run(sf, :a, fn -> 1 end) == 1
    assert SingleFlight.run(sf, :b, fn -> 2 end) == 2
  end

  test "the key is free again after completion, so the next call runs afresh", %{sf: sf} do
    counter = :counters.new(1, [])
    fun = fn -> :counters.add(counter, 1, 1) end

    SingleFlight.run(sf, :k, fun)
    SingleFlight.run(sf, :k, fun)

    assert :counters.get(counter, 1) == 2
  end

  @tag :capture_log
  test "a crash is reported to every waiter and frees the key", %{sf: sf} do
    gate = start_gate()

    crashing = fn ->
      receive_release(gate)
      raise "boom"
    end

    tasks = for _ <- 1..3, do: Task.async(fn -> SingleFlight.run(sf, :k, crashing) end)
    await_waiters(sf, :k, 3)
    send(gate, {:open, :go})

    for result <- Enum.map(tasks, &Task.await/1) do
      assert {:error, {:crashed, {%RuntimeError{message: "boom"}, _stack}}} = result
    end

    assert SingleFlight.run(sf, :k, fn -> :recovered end) == :recovered
  end

  test "a caller timing out gets {:error, :timeout} without cancelling the run for others", %{
    sf: sf
  } do
    gate = start_gate()
    fun = gated_fun(:counters.new(1, []), gate)

    patient = Task.async(fn -> SingleFlight.run(sf, :k, fun) end)
    await_waiters(sf, :k, 1)

    assert SingleFlight.run(sf, :k, fun, 10) == {:error, :timeout}

    send(gate, {:open, :done})
    assert Task.await(patient) == :done
  end

  test "in-flight runners die with the server, so a restarted registry can't overlap them", %{
    sf: sf
  } do
    gate = start_gate()

    caller =
      Task.async(fn ->
        catch_exit(SingleFlight.run(sf, :k, gated_fun(:counters.new(1, []), gate)))
      end)

    await_waiters(sf, :k, 1)
    [runner] = sf |> :sys.get_state() |> Map.fetch!(:runners) |> Map.keys()
    ref = Process.monitor(runner)

    Process.exit(Process.whereis(sf), :kill)

    assert_receive {:DOWN, ^ref, :process, ^runner, :killed}
    Task.await(caller)
  end

  test "any term works as a key, including nil", %{sf: sf} do
    assert SingleFlight.run(sf, nil, fn -> :nil_key end) == :nil_key
    assert SingleFlight.run(sf, nil, fn -> :again end) == :again
  end

  test "an orderly stop also ends in-flight runners", %{sf: sf} do
    gate = start_gate()

    caller =
      Task.async(fn ->
        catch_exit(SingleFlight.run(sf, :k, gated_fun(:counters.new(1, []), gate)))
      end)

    await_waiters(sf, :k, 1)
    [runner] = sf |> :sys.get_state() |> Map.fetch!(:runners) |> Map.keys()
    ref = Process.monitor(runner)

    GenServer.stop(sf)

    assert_receive {:DOWN, ^ref, :process, ^runner, :killed}
    Task.await(caller)
  end
end
