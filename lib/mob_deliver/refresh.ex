defmodule MobDeliver.Refresh do
  @moduledoc false
  # The newest signed manifest, for a JIT miss (MobDeliver.Resolver): a
  # module neither the active manifest nor the binary has may have been
  # published since the last install. At most one fetch per
  # `:refresh_interval` ms however many misses ask: concurrent callers share
  # the in-flight fetch, and callers inside the window get its result —
  # failures included — so a burst of misses, a mistyped module or an
  # offline device can't turn navigation into a request storm.
  #
  # Nothing is installed here: the result only tells the resolver where to
  # fetch one screen's modules from (see the ADR's "JIT navigation").

  use GenServer

  require Logger

  alias MobDeliver.{Client, Gate, Manifest, SingleFlight, Store}

  @type result :: {:ok, Store.manifest_id(), Manifest.t()} | {:error, term()}

  @doc "Options: `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  The latest manifest from the server — `{:fresh, result}` — or the result
  of a fetch less than `opts[:refresh_interval]` ms old —
  `{:cached, age_ms, result}`. Uses `opts[:refresh]`, `:single_flight`,
  `:gate` and `:client_opts`. `{:error, _}` if the shared fetch itself
  failed to run (`MobDeliver.SingleFlight`).
  """
  @spec latest(keyword()) ::
          {:fresh, result()} | {:cached, non_neg_integer(), result()} | {:error, term()}
  def latest(opts) do
    with :stale <- cached(opts) do
      # Re-checked inside the flight: one may have finished just before.
      SingleFlight.run(opts[:single_flight], :refresh, fn ->
        with :stale <- cached(opts), do: {:fresh, fetch(opts)}
      end)
    end
  end

  defp cached(opts) do
    case :ets.lookup(table(opts[:refresh]), :last) do
      [{:last, at, result}] ->
        age = System.monotonic_time(:millisecond) - at
        if age < opts[:refresh_interval], do: {:cached, age, result}, else: :stale

      [] ->
        :stale
    end
  end

  defp fetch(opts) do
    result =
      with {:ok, manifest, body} <- Client.fetch_manifest(opts[:client_opts]) do
        # Like any verified manifest, it governs the update gate.
        with {:error, reason} <- Gate.record(opts[:gate], body, manifest) do
          Logger.warning(
            "mob_deliver: could not record update-gate manifest (#{inspect(reason)})"
          )
        end

        {:ok, Store.manifest_id(body), manifest}
      end

    GenServer.call(opts[:refresh], {:put, result})
    result
  end

  @impl true
  def init(name) do
    :ets.new(table(name), [:named_table, :protected, read_concurrency: true])
    {:ok, table(name)}
  end

  @impl true
  def handle_call({:put, result}, _from, table) do
    :ets.insert(table, {:last, System.monotonic_time(:millisecond), result})
    {:reply, :ok, table}
  end

  defp table(name) when is_atom(name), do: :"#{name}.table"
end
