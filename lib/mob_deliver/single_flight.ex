defmodule MobDeliver.SingleFlight do
  @moduledoc """
  Collapses concurrent calls for the same key into one execution.

  The first `run/4` for a key starts `fun` in a separate process; callers
  that arrive while it is in flight wait for the same result instead of
  starting their own. Once it finishes, the key is free again, so the next
  call runs `fun` afresh (results are not cached).

  `fun` runs outside the caller, so a caller that times out or dies does
  not cancel it for the others. Runners are linked to this server and
  killed when it terminates (crash or orderly stop), so a restarted
  registry never overlaps a leftover execution. `fun` must be bounded
  (e.g. HTTP timeouts): a hung `fun` holds its key until it returns.
  """

  use GenServer

  @type result :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Runs `fun` for `key`, or waits for the in-flight run of `key`.

  Returns `fun`'s result, `{:error, {:crashed, reason}}` if it raised or
  exited, or `{:error, :timeout}` after `timeout` ms (default 60s) for this
  caller only.
  """
  @spec run(GenServer.server(), term(), (-> result()), timeout()) ::
          result() | {:error, :timeout | {:crashed, term()}}
  def run(server, key, fun, timeout \\ 60_000) when is_function(fun, 0) do
    GenServer.call(server, {:run, key, fun}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{waiting: %{}, runners: %{}}}
  end

  @impl true
  def handle_call({:run, key, fun}, from, state) do
    case state.waiting do
      %{^key => callers} ->
        {:noreply, put_in(state.waiting[key], [from | callers])}

      _ ->
        # The result travels in the exit reason, so it can't race the exit.
        pid = spawn_link(fn -> exit({:single_flight_result, fun.()}) end)

        {:noreply,
         %{
           waiting: Map.put(state.waiting, key, [from]),
           runners: Map.put(state.runners, pid, key)
         }}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    case Map.fetch(state.runners, pid) do
      :error ->
        {:noreply, state}

      {:ok, key} ->
        {callers, waiting} = Map.pop!(state.waiting, key)

        reply =
          case reason do
            {:single_flight_result, result} -> result
            other -> {:error, {:crashed, other}}
          end

        Enum.each(callers, &GenServer.reply(&1, reply))
        {:noreply, %{waiting: waiting, runners: Map.delete(state.runners, pid)}}
    end
  end

  # Linked runners ignore a :normal exit signal, so an orderly stop must
  # kill them explicitly.
  @impl true
  def terminate(_reason, state) do
    state.runners |> Map.keys() |> Enum.each(&Process.exit(&1, :kill))
  end
end
