defmodule MobDeliver.Boot do
  @moduledoc false
  # The plugin's on_start: runs synchronously before the host app's own
  # on_start, i.e. before any app screen exists. Must never raise or hang —
  # a raise aborts the whole app boot (Mob.Plugins.Supervisor re-raises),
  # and nothing after us runs until we return.

  require Logger

  alias MobDeliver.{Build, Bundled, Config, Loader, Manifest, Poller, Store, Watchdog}

  @load_timeout 5_000

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    watchdog = Keyword.get(opts, :watchdog, Watchdog)

    case readiness(store, opts) do
      :ok ->
        # Anything that fails after Store.boot/2 has published the active
        # manifest must unpublish it: delivered code never runs unprobated.
        guarded("boot", fn -> probation_boot(store, watchdog, opts) end, fn ->
          Store.unpublish(store)
        end)

        guarded("update services", fn -> start_services(opts) end, fn -> :ok end)

      {:skip, why} ->
        # Nothing is touched: the stored manifests, probation state and
        # rejections stay as they are for a boot that can use them.
        Logger.warning("mob_deliver: #{why}; running bundled code, no update checks")
    end

    :ok
  end

  # Without its processes (the OTP application not started: mob < 0.9.6
  # doesn't start plugin applications) every call would exit, and the
  # router hook would refuse all navigation. Without app/channel the
  # verifier would reject — and discard — every stored manifest.
  defp readiness(store, opts) do
    missing = if Keyword.has_key?(opts, :verify), do: [], else: Config.missing()

    cond do
      GenServer.whereis(store) == nil ->
        {:skip,
         "the :mob_deliver application isn't running (mob >= 0.9.6 starts plugin applications before their on_start)"}

      missing != [] ->
        {:skip,
         "not configured (#{Enum.map_join(missing, ", ", &inspect/1)} unset in config :mob_deliver, " <>
           "or the app config didn't reach the device: that needs mob >= 0.9.6 and its mob_dev)"}

      true ->
        :ok
    end
  end

  @doc "Verifies a stored or fetched manifest body against this build's key, app, and channel."
  @spec verifier() :: Store.verify_fun()
  def verifier do
    key = Config.trusted_publish_key()
    expected = [app: Config.app(), channel: Config.channel()]
    &Manifest.verify(&1, key, expected)
  end

  defp probation_boot(store, watchdog, opts) do
    verify = Keyword.get_lazy(opts, :verify, &verifier/0)
    {:ok, _} = Store.boot(store, verify)

    # Before the watchdog's check, so a manifest the build has outgrown is
    # retired, not rolled back (no rejection, no notice); and after, in
    # case a rollback lands on an outgrown previous one.
    index = Bundled.index()
    retire_if_stale(store, watchdog, index)

    case Watchdog.on_boot(watchdog, verify) do
      {:ok, outcome} ->
        if outcome == :rolled_back do
          log_rollback(store)
          retire_if_stale(store, watchdog, index)
        end

        load_active(store, watchdog, Keyword.get(opts, :load_timeout, @load_timeout))

        # Nothing can be fetching yet: update checks start later, and no app
        # code (resolve/1) has run.
        with {:error, reason} <- Store.gc(store) do
          Logger.warning("mob_deliver: blob cleanup skipped (#{inspect(reason)})")
        end

      {:error, reason} ->
        Logger.error(
          "mob_deliver: probation state unavailable (#{inspect(reason)}); running bundled code"
        )

        Store.unpublish(store)
    end
  end

  defp log_rollback(store) do
    case Store.active_id(store) do
      nil -> Logger.warning("mob_deliver: rolled back; booting bundled code")
      id -> Logger.warning("mob_deliver: rolled back; booting the previous manifest #{id}")
    end
  end

  # The bundled code changed under the active manifest (a new native build
  # or a BEAM push): its delivered versions would override newer code, so
  # the app runs its bundled code and the manifest's outgrown versions are
  # remembered, so re-fetching it doesn't reinstall it. Not a failure: no
  # rejection, no rollback notice. If that can't be recorded durably, this
  # session still runs bundled code and the next boot tries again.
  defp retire_if_stale(store, watchdog, index) do
    with {id, manifest} <- Store.active(store) do
      case Build.check(store, id, manifest, index) do
        :ok ->
          :ok

        {:adopt, base} ->
          with {:error, reason} <- Store.put_base(store, id, base) do
            Logger.warning(
              "mob_deliver: couldn't record the build #{id} runs on (#{inspect(reason)})"
            )
          end

        {:stale, pairs} ->
          Logger.warning(
            "mob_deliver: this build's bundled code is newer than manifest #{id}'s " <>
              "#{Enum.map_join(pairs, ", ", fn {key, _} -> key end)}; running the bundled code " <>
              "(publish again from this build's source to deliver updates)"
          )

          with :ok <- Watchdog.supersede(watchdog, pairs),
               :ok <- Store.retire(store, id) do
            :ok
          else
            {:error, reason} ->
              Logger.error(
                "mob_deliver: couldn't retire manifest #{id} (#{inspect(reason)}); " <>
                  "running bundled code this launch"
              )

              Store.unpublish(store)
          end
      end
    end
  end

  defp start_services(opts) do
    # Navigation resolves and gates itself; first idle is the root screen's
    # first paint.
    MobDeliver.Hooks.register()

    # `poller: nil` skips update checks (tests).
    if poller = Keyword.get(opts, :poller, Poller) do
      Poller.register_push()
      Poller.start(poller)
    end
  end

  defp guarded(what, fun, on_failure) do
    fun.()
  catch
    kind, reason ->
      Logger.error(
        "mob_deliver: #{what} failed, running bundled code: #{Exception.format(kind, reason, __STACKTRACE__)}"
      )

      try do
        on_failure.()
      catch
        _, _ -> :ok
      end
  end

  # Delivered versions of everything already on the device, loaded before
  # the app's code runs, callees before callers (an @on_load may call into a
  # delivered-only callee). Modules whose blob isn't local are left to
  # resolve/1 (JIT) or the next boot — and so is every module that calls
  # one of them: loaded, it would count as resolved and call a version of
  # its callee this manifest doesn't deliver (or none at all).
  #
  # What's about to load is recorded with the watchdog first (durably while
  # on probation), so a launch that dies suspects only modules that ran.
  # If that can't be recorded, nothing delivered loads: fail closed.
  defp load_active(store, watchdog, timeout) do
    with {_id, %Manifest{modules: modules}} <- Store.active(store) do
      local =
        for {key, sha} <- modules, {:ok, binary} <- [local_blob(store, key, sha)], into: %{} do
          {Manifest.key_module(key), {sha, binary}}
        end

      local = complete_closures(local, modules)
      pairs = Map.new(local, fn {module, {sha, _}} -> {Manifest.module_key(module), sha} end)

      case Watchdog.note_loaded(watchdog, pairs) do
        :ok ->
          local
          |> callees_first()
          |> Enum.each(fn module ->
            {sha, binary} = Map.fetch!(local, module)
            load_bounded(module, binary, Store.blob_path(store, sha), timeout)
          end)

        {:error, reason} ->
          Logger.error(
            "mob_deliver: couldn't record what this launch loads (#{inspect(reason)}); " <>
              "running bundled code"
          )

          Store.unpublish(store)
      end
    end

    :ok
  end

  # Drops local modules whose delivered callees aren't all local, until
  # nothing changes (a caller of a dropped module is dropped too).
  defp complete_closures(local, modules) do
    delivered_callees =
      Map.new(local, fn {module, {_sha, binary}} ->
        callees =
          binary
          |> Loader.imported_modules()
          |> Enum.filter(&Map.has_key?(modules, Manifest.module_key(&1)))

        {module, callees}
      end)

    drop_incomplete(local, delivered_callees)
  end

  defp drop_incomplete(local, delivered_callees) do
    incomplete =
      Enum.find_value(local, fn {module, _} ->
        missing = Enum.find(delivered_callees[module], &(not Map.has_key?(local, &1)))
        missing && {module, missing}
      end)

    case incomplete do
      nil ->
        local

      {module, missing} ->
        Logger.info(
          "mob_deliver: #{inspect(module)} not loaded at boot: its delivered callee " <>
            "#{inspect(missing)} isn't on the device; both load on first use"
        )

        drop_incomplete(Map.delete(local, module), delivered_callees)
    end
  end

  # A missing blob is normal (a JIT module not fetched yet). Anything else
  # means the stored copy is unusable; resolve/1 re-fetches it on first use.
  defp local_blob(store, key, sha) do
    with {:error, reason} = error when reason != :missing <- Store.read_blob(store, sha) do
      Logger.warning(
        "mob_deliver: stored #{key} (#{sha}) unreadable (#{inspect(reason)}); " <>
          "not loaded at boot, re-fetched on first use"
      )

      error
    end
  end

  # Depth-first post-order over the imports graph restricted to `local`.
  defp callees_first(local) do
    {order, _seen} =
      local
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, &visit(&1, &2, local))

    Enum.reverse(order)
  end

  defp visit(module, {order, seen} = acc, local) do
    if MapSet.member?(seen, module) or not Map.has_key?(local, module) do
      acc
    else
      {_sha, binary} = Map.fetch!(local, module)

      {order, seen} =
        binary
        |> Loader.imported_modules()
        |> Enum.reduce({order, MapSet.put(seen, module)}, &visit(&1, &2, local))

      {[module | order], seen}
    end
  end

  # An @on_load callback is delivered code and must not hold the app's boot
  # hostage. The code server runs it in its own process, so abandoning the
  # waiting caller isn't enough — that exact process is killed too, which
  # fails the load and releases anyone else waiting on the module.
  #
  # Only *our* pending load is ever cancelled. If someone else's @on_load
  # for the module is already pending, the module is skipped: our request
  # would queue behind theirs where it can neither finish nor be cancelled.
  defp load_bounded(module, binary, source, timeout) do
    case on_load_pending(module) do
      {:ok, _someone_elses} ->
        Logger.warning(
          "mob_deliver: #{inspect(module)} has another @on_load pending; not loading it at boot"
        )

      # :unknown (state unreadable) loads as usual; a timeout then just can't
      # be cancelled (logged).
      _none_or_unknown ->
        run_bounded(module, binary, source, timeout)
    end
  end

  defp run_bounded(module, binary, source, timeout) do
    task = Task.async(fn -> Loader.load(module, binary, source) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning(
          "mob_deliver: could not load #{inspect(module)} at boot (#{inspect(reason)})"
        )

      {:exit, reason} ->
        Logger.warning("mob_deliver: loading #{inspect(module)} crashed (#{inspect(reason)})")

      nil ->
        cancel_on_load(module, task.pid, timeout)
    end
  end

  defp cancel_on_load(module, client, timeout) do
    case on_load_pending(module) do
      {:ok, {^client, runner}} ->
        Process.exit(runner, :kill)

        Logger.warning(
          "mob_deliver: #{inspect(module)}'s @on_load exceeded #{timeout}ms; load cancelled"
        )

      _ ->
        Logger.error(
          "mob_deliver: #{inspect(module)}'s @on_load exceeded #{timeout}ms and couldn't be cancelled"
        )
    end
  end

  # The code server tracks pending callbacks as
  # `on_load: %{module => {file, client, runner}}` in its state (OTP 28/29),
  # readable through sys:get_status/2: the requesting client and the runner
  # identify a load exactly. `:none` when nothing is pending, `:unknown` if
  # the state can't be read (then nothing is killed).
  defp on_load_pending(module) do
    with pid when is_pid(pid) <- Process.whereis(:code_server),
         {:status, ^pid, {:module, :code_server}, [_dict, _sys, _parent, _debug, state]}
         when is_tuple(state) <-
           :sys.get_status(pid, 1_000) do
      state
      |> Tuple.to_list()
      |> Enum.find_value(:none, fn
        %{^module => {_file, client, runner}} when is_pid(runner) -> {:ok, {client, runner}}
        _ -> nil
      end)
    else
      _ -> :unknown
    end
  catch
    _, _ -> :unknown
  end
end
