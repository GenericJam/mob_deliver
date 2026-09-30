defmodule MobDeliver.GateNavigation do
  @moduledoc false
  # Keeps what's on screen in step with the forced-update gate mid-session:
  #
  #   * the gate is :required and a user screen is showing → replace all
  #     navigation with the update screen;
  #   * the gate is open and the update screen is showing → replace it with
  #     the app's root, the screen MobDeliver.root_screen/2 was asked for.
  #
  # Requested when the gate's verdict changes (MobDeliver.Gate's :on_change)
  # and at the root screen's first frame (a change that landed before the
  # router existed). One process does all of it, so reconciliations never
  # overlap, and each one reads the gate *now* — a request is only "look
  # again", so an old change can't be applied after a newer one. Requests
  # arriving while one runs coalesce into one more pass. A router too busy
  # to answer (e.g. mid-download of a JIT screen) is retried, not dropped.
  #
  # Navigation goes through the router's normal path, so mob_deliver's
  # :before_navigate hook still has the last word. The router is called from
  # this process only: never from the router (it calls the hook) or the gate
  # (the hook reads it).

  use GenServer

  require Logger

  alias MobDeliver.{Config, Gate, Watchdog}

  @root {MobDeliver, :root}
  @retry_ms 1_000

  @type outcome :: :locked | :released | :noop | :retry

  @doc """
  Options: `:name`, and for tests `:router` (0-arity fun returning the
  router or nil; default `:mob_screen`), `:status` (0-arity fun; default
  `MobDeliver.Gate.status/0`), `:watchdog`, `:call_timeout` (ms, default
  30s), `:retry_ms`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Asks for a reconciliation against the current gate. Never blocks or raises."
  @spec request(GenServer.server()) :: :ok
  def request(server \\ __MODULE__), do: GenServer.cast(server, :request)

  @doc """
  Remembers the root screen the app asked `MobDeliver.root_screen/2` for,
  which screen it booted into, and its update screen.
  """
  @spec put_root(module(), module(), module()) :: :ok
  def put_root(requested, booted, update_screen),
    do:
      :persistent_term.put(@root, %{
        requested: requested,
        booted: booted,
        update_screen: update_screen
      })

  @doc "What `put_root/3` recorded, or `nil`."
  @spec root() :: %{requested: module(), booted: module(), update_screen: module()} | nil
  def root, do: :persistent_term.get(@root, nil)

  @doc "The update screen: the one given to `MobDeliver.root_screen/2`, else `:update_screen` config, else the default."
  @spec update_screen() :: module()
  def update_screen do
    case root() do
      %{update_screen: screen} -> screen
      nil -> Config.get(:update_screen) || MobDeliver.UpdateRequiredScreen
    end
  end

  # ── server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       router: Keyword.get(opts, :router, fn -> Process.whereis(:mob_screen) end),
       status: Keyword.get(opts, :status, fn -> Gate.status() end),
       watchdog: Keyword.get(opts, :watchdog, Watchdog),
       call_timeout: Keyword.get(opts, :call_timeout, 30_000),
       retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
       scheduled: false
     }}
  end

  # Coalesce: one pending pass covers every request made before it runs.
  @impl true
  def handle_cast(:request, %{scheduled: true} = s), do: {:noreply, s}

  def handle_cast(:request, s) do
    send(self(), :reconcile)
    {:noreply, %{s | scheduled: true}}
  end

  @impl true
  def handle_info(:reconcile, s) do
    s = %{s | scheduled: false}

    case reconcile(s) do
      :retry ->
        Process.send_after(self(), :retry, s.retry_ms)
        {:noreply, s}

      _done ->
        {:noreply, s}
    end
  end

  def handle_info(:retry, s), do: handle_cast(:request, s)

  def handle_info(_other, s), do: {:noreply, s}

  defp reconcile(s) do
    case s.router.() do
      nil ->
        :noop

      router ->
        current = GenServer.call(router, :get_current_module, s.call_timeout)
        apply_gate(s, router, s.status.(), current, update_screen(), root_requested())
    end
  catch
    :exit, {:timeout, _} ->
      Logger.info("mob_deliver: navigation is busy; applying the update gate again shortly")
      :retry

    kind, reason ->
      Logger.warning(
        "mob_deliver: couldn't apply the update gate to navigation (#{Exception.format_banner(kind, reason)})"
      )

      :noop
  end

  defp apply_gate(s, router, {:required, _}, current, update_screen, _root)
       when current != update_screen do
    Logger.warning(
      "mob_deliver: this app version is past its forced-update deadline; showing #{inspect(update_screen)}"
    )

    reset(s, router, update_screen)
    :locked
  end

  defp apply_gate(_s, _router, {:required, _}, _current, _update_screen, _root), do: :noop

  defp apply_gate(_s, _router, _open, current, update_screen, _root)
       when current != update_screen,
       do: :noop

  defp apply_gate(_s, _router, _open, _current, _update_screen, nil) do
    Logger.warning(
      "mob_deliver: the update gate is open again, but the app's root screen is unknown " <>
        "(boot through MobDeliver.root_screen/2); the update screen stays until the next launch"
    )

    :noop
  end

  defp apply_gate(s, router, _open, _current, _update_screen, root) do
    Logger.info("mob_deliver: the update gate is open again; back to #{inspect(root)}")

    # The booted update's screens run from here on: its probation starts now
    # (a gated first frame didn't count), and the root's first frame ends it.
    with {:error, reason} <- Watchdog.resume_probation(s.watchdog) do
      Logger.warning("mob_deliver: couldn't resume probation (#{inspect(reason)})")
    end

    reset(s, router, root)
    :released
  end

  defp reset(s, router, screen),
    do:
      GenServer.call(
        router,
        {:navigate, {:reset, screen, %{}, :reset, :all}},
        s.call_timeout
      )

  defp root_requested do
    case root() do
      %{requested: requested} -> requested
      nil -> nil
    end
  end
end
