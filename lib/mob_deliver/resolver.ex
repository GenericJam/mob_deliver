defmodule MobDeliver.Resolver do
  @moduledoc false
  # JIT delivery: make `module` callable, fetching it (and the delivered
  # modules it calls) on a cache miss. See MobDeliver.resolve/1.

  alias MobDeliver.{Client, Config, Loader, Manifest, SingleFlight, Store}

  @type opts :: [store: Store.server(), single_flight: GenServer.server(), client_opts: keyword()]

  @spec resolve(module(), opts()) :: :ok | {:error, term()}
  def resolve(module, opts \\ []) when is_atom(module) do
    opts = defaults(opts)

    # One manifest for the whole closure: an activation mid-resolve must not
    # pair this release's target with the next release's helpers.
    with false <- :code.is_loaded(module) != false,
         {_id, %Manifest{modules: modules}} <- Store.active(opts[:store]),
         {:ok, _sha} <- Map.fetch(modules, Manifest.module_key(module)) do
      SingleFlight.run(opts[:single_flight], {:resolve, module}, fn ->
        deliver(module, modules, opts)
      end)
    else
      true -> :ok
      _not_delivered -> bundled(module)
    end
  end

  defp defaults(opts) do
    opts
    |> Keyword.put_new(:store, Store)
    |> Keyword.put_new(:single_flight, SingleFlight)
    |> Keyword.put_new_lazy(:client_opts, &Config.client_opts/0)
  end

  defp bundled(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  # Every delivered, not-yet-loaded module in the call closure is fetched
  # before anything loads, then loaded callees-first with the target last:
  # the target only becomes visible (to concurrent resolves, to @on_load)
  # once everything it calls is loaded, and a failed callee leaves it
  # unloaded so the next resolve retries.
  defp deliver(module, modules, opts) do
    with {:ok, order} <- closure([module], [], MapSet.new(), modules, opts) do
      Enum.reduce_while(order, :ok, fn {mod, sha, binary}, :ok ->
        case load_once(mod, sha, binary, opts) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # Breadth-first from the target; the result is reversed discovery order,
  # so deeper callees come first and the target last.
  defp closure([], found, _seen, _modules, _opts), do: {:ok, found}

  defp closure([mod | rest], found, seen, modules, opts) do
    with false <- MapSet.member?(seen, mod) or :code.is_loaded(mod) != false,
         {:ok, sha} <- Map.fetch(modules, Manifest.module_key(mod)),
         {:ok, binary} <- blob(sha, opts) do
      next = rest ++ Loader.imported_modules(binary)
      closure(next, [{mod, sha, binary} | found], MapSet.put(seen, mod), modules, opts)
    else
      # Already collected/loaded, or not delivered (bundled/OTP): skip.
      skip when skip in [true, :error] -> closure(rest, found, seen, modules, opts)
      {:error, _} = error -> error
    end
  end

  defp blob(sha, opts) do
    with {:error, reason} when reason in [:missing, :corrupt] <-
           Store.read_blob(opts[:store], sha) do
      SingleFlight.run(opts[:single_flight], {:blob, sha}, fn -> fetch_blob(sha, opts) end)
    end
  end

  # Re-checked inside the flight: another resolve may have stored it
  # between our read and acquiring the key.
  defp fetch_blob(sha, opts) do
    with {:error, reason} when reason in [:missing, :corrupt] <-
           Store.read_blob(opts[:store], sha),
         {:ok, binary} <- Client.fetch_beam(sha, opts[:client_opts]),
         :ok <- Store.put_blob(opts[:store], sha, binary) do
      {:ok, binary}
    end
  end

  # Another resolve may be loading the same callee concurrently.
  defp load_once(mod, sha, binary, opts) do
    SingleFlight.run(opts[:single_flight], {:load, mod}, fn ->
      if :code.is_loaded(mod),
        do: :ok,
        else: Loader.load(mod, binary, Store.blob_path(opts[:store], sha))
    end)
  end
end
