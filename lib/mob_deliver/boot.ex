defmodule MobDeliver.Boot do
  @moduledoc false
  # The plugin's on_start: runs synchronously before the host app's own
  # on_start, i.e. before any app screen exists. Must never raise or hang —
  # a raise aborts the whole app boot (Mob.Plugins.Supervisor re-raises),
  # and nothing after us runs until we return.

  require Logger

  alias MobDeliver.{Config, Loader, Manifest, Poller, Store, Watchdog}

  @load_timeout 5_000

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    store = Keyword.get(opts, :store, Store)
    watchdog = Keyword.get(opts, :watchdog, Watchdog)

    # Anything that fails after Store.boot/2 has published the active
    # manifest must unpublish it: delivered code never runs unprobated.
    guarded("boot", fn -> probation_boot(store, watchdog, opts) end, fn ->
      Store.unpublish(store)
    end)

    guarded("update services", fn -> start_services(watchdog, opts) end, fn -> :ok end)
    :ok
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

    case Watchdog.on_boot(watchdog, verify) do
      {:ok, outcome} ->
        if outcome == :rolled_back,
          do: Logger.warning("mob_deliver: booting the rolled-back manifest")

        load_active(store, Keyword.get(opts, :load_timeout, @load_timeout))

      {:error, reason} ->
        Logger.error(
          "mob_deliver: probation state unavailable (#{inspect(reason)}); running bundled code"
        )

        Store.unpublish(store)
    end
  end

  defp start_services(watchdog, opts) do
    Watchdog.mark_stable_after(
      watchdog,
      Keyword.get_lazy(opts, :stable_after, &Config.stable_after/0)
    )

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
  # resolve/1 (JIT) or the next boot.
  defp load_active(store, timeout) do
    with {_id, %Manifest{modules: modules}} <- Store.active(store) do
      local =
        for {key, sha} <- modules, {:ok, binary} <- [Store.read_blob(store, sha)], into: %{} do
          {Manifest.key_module(key), {sha, binary}}
        end

      local
      |> callees_first()
      |> Enum.each(fn module ->
        {sha, binary} = Map.fetch!(local, module)
        load_bounded(module, binary, Store.blob_path(store, sha), timeout)
      end)
    end

    :ok
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
