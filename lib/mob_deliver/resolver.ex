defmodule MobDeliver.Resolver do
  @moduledoc false
  # JIT delivery: make `module` callable, fetching it (and the delivered
  # modules it calls) on a cache miss. See MobDeliver.resolve/1.

  require Logger

  alias MobDeliver.{
    Config,
    Fetcher,
    Gate,
    Loader,
    Manifest,
    Refresh,
    SingleFlight,
    Store,
    Watchdog
  }

  @type opts :: [
          store: Store.server(),
          single_flight: GenServer.server(),
          gate: GenServer.server(),
          watchdog: GenServer.server(),
          refresh: GenServer.server(),
          refresh_interval: non_neg_integer(),
          client_opts: keyword(),
          app_version: String.t() | nil
        ]

  @spec resolve(module(), opts()) :: :ok | {:error, term()}
  def resolve(module, opts \\ []) when is_atom(module) do
    opts = defaults(opts)

    # Past the forced-update deadline nothing navigates, loaded or not: the
    # gate runs before navigation.
    with :ok <- open_gate(opts),
         false <- :code.is_loaded(module) != false,
         # One manifest for the whole closure: an activation mid-resolve must
         # not pair this release's target with the next release's helpers.
         {:ok, modules} <- manifest_for(module, opts) do
      SingleFlight.run(opts[:single_flight], {:resolve, module}, fn ->
        deliver(module, modules, opts)
      end)
    else
      {:error, _} = error -> error
      true -> :ok
      :bundled -> bundled(module)
    end
  end

  defp defaults(opts) do
    opts
    |> Keyword.put_new(:store, Store)
    |> Keyword.put_new(:single_flight, SingleFlight)
    |> Keyword.put_new(:gate, Gate)
    |> Keyword.put_new(:watchdog, Watchdog)
    |> Keyword.put_new(:refresh, Refresh)
    |> Keyword.put_new_lazy(:refresh_interval, &Config.refresh_interval/0)
    |> Keyword.put_new_lazy(:client_opts, &Config.client_opts/0)
    |> Keyword.put_new_lazy(:app_version, &Config.app_version/0)
  end

  defp open_gate(opts) do
    case Gate.status(opts[:gate], Keyword.take(opts, [:app_version, :now])) do
      {:required, _} -> {:error, :update_required}
      _ -> :ok
    end
  end

  # The active manifest's module map if it delivers `module`. A module that
  # neither it nor the binary has may have been published since the last
  # install (or nothing is installed yet): look at the server's newest
  # manifest (rate-limited, see MobDeliver.Refresh) and, if that delivers
  # it, take this module's closure from there — without installing it.
  # Route atoms are the router's business and never trigger a fetch.
  defp manifest_for(module, opts) do
    key = Manifest.module_key(module)

    case delivering(key, opts) do
      {:ok, _} = found ->
        found

      _absent_or_none ->
        cond do
          :code.which(module) != :non_existing or route?(module) ->
            :bundled

          # Code that isn't installed has no probation record, so it must not
          # be able to take down a launch: nothing from a refresh runs before
          # the root screen's first frame (see the ADR).
          not Watchdog.first_idle?(opts[:watchdog]) ->
            Logger.info(
              "mob_deliver: #{inspect(module)} isn't in the installed manifest; " <>
                "not asking the server before the first screen has rendered"
            )

            :bundled

          true ->
            refreshed(module, key, opts)
        end
    end
  end

  defp refreshed(module, key, opts) do
    {result, age} =
      case Refresh.latest(opts) do
        {:fresh, result} -> {result, nil}
        {:cached, age, result} -> {result, age}
        {:error, _} = error -> {error, nil}
      end

    with {:ok, id, %Manifest{modules: modules} = latest} <- explained(result, module, age, opts),
         # The refreshed manifest may have moved this app past its deadline.
         :ok <- open_gate(opts) do
      cond do
        # An install may have landed while we fetched.
        match?({:ok, _}, delivering(key, opts)) ->
          delivering(key, opts)

        not Map.has_key?(modules, key) ->
          log_absent(module, age, opts)
          :bundled

        runnable?(id, latest, opts) ->
          {:ok, modules}

        true ->
          Logger.warning(
            "mob_deliver: #{inspect(module)} is in the server's newest manifest, but that " <>
              "manifest is below this app's floor or was rolled back on this device"
          )

          :bundled
      end
    end
  end

  # A failure reused from the last refresh: say so, or the navigation just
  # looks refused for no reason.
  defp explained({:error, reason} = error, module, age, opts) when age != nil do
    Logger.warning(
      "mob_deliver: #{inspect(module)}: the last manifest refresh #{div(age, 1000)}s ago failed " <>
        "(#{inspect(reason)}); next refresh allowed in #{next_refresh(age, opts)}s"
    )

    error
  end

  defp explained(result, _module, _age, _opts), do: result

  # The router's own error for an unknown destination says nothing about
  # delivery; this does.
  defp log_absent(module, nil, _opts),
    do: Logger.info("mob_deliver: #{inspect(module)} isn't in the server's newest manifest")

  defp log_absent(module, age, opts) do
    Logger.info(
      "mob_deliver: #{inspect(module)} isn't in the manifest fetched #{div(age, 1000)}s ago; " <>
        "next refresh allowed in #{next_refresh(age, opts)}s"
    )
  end

  defp next_refresh(age, opts), do: div(max(opts[:refresh_interval] - age, 0) + 999, 1000)

  # The same bar an install has to clear: built for this app version, and
  # not content this device rolled back.
  defp runnable?(id, manifest, opts) do
    Gate.installable?(manifest, opts[:app_version]) and
      not Watchdog.rejected?(opts[:watchdog], id, manifest)
  end

  defp route?(dest) do
    match?({:ok, _, _}, Mob.Nav.Registry.lookup_route(dest))
  rescue
    # No registry table (host tests, a VM without mob's navigation).
    ArgumentError -> false
  end

  defp delivering(key, opts) do
    case Store.active(opts[:store]) do
      {_id, %Manifest{modules: %{^key => _} = modules}} -> {:ok, modules}
      {_id, _} -> :absent
      nil -> :none
    end
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
  # unloaded so the next resolve retries. The closure is recorded with the
  # watchdog before it loads (durably during a probation launch), so a
  # rollback suspects what ran; if that fails, nothing loads.
  defp deliver(module, modules, opts) do
    with {:ok, order} <- closure([module], [], MapSet.new(), modules, opts),
         :ok <- note_loaded(order, opts) do
      Enum.reduce_while(order, :ok, fn {mod, sha, binary}, :ok ->
        case load_once(mod, sha, binary, opts) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp note_loaded([], _opts), do: :ok

  defp note_loaded(order, opts) do
    pairs = Map.new(order, fn {mod, sha, _binary} -> {Manifest.module_key(mod), sha} end)
    Watchdog.note_loaded(opts[:watchdog], pairs)
  end

  # Breadth-first from the target; the result is reversed discovery order,
  # so deeper callees come first and the target last.
  defp closure([], found, _seen, _modules, _opts), do: {:ok, found}

  defp closure([mod | rest], found, seen, modules, opts) do
    with false <- MapSet.member?(seen, mod) or :code.is_loaded(mod) != false,
         {:ok, sha} <- Map.fetch(modules, Manifest.module_key(mod)),
         {:ok, binary} <- Fetcher.ensure_blob(sha, opts) do
      next = rest ++ Loader.imported_modules(binary)
      closure(next, [{mod, sha, binary} | found], MapSet.put(seen, mod), modules, opts)
    else
      # Already collected/loaded, or not delivered (bundled/OTP): skip.
      skip when skip in [true, :error] -> closure(rest, found, seen, modules, opts)
      {:error, _} = error -> error
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
