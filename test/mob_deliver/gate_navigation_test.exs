defmodule MobDeliver.GateNavigationTest do
  # A real router over mob's shared navigation state: not async.
  use Mob.ScreenCase

  alias MobDeliver.{GateNavigation, UpdateRequiredScreen}

  @moduletag :capture_log

  defmodule HomeScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "home"}, children: []}
  end

  defmodule DetailScreen do
    use Mob.Screen
    def mount(_params, _session, socket), do: {:ok, socket}
    def render(_assigns), do: %{type: :text, props: %{text: "detail"}, children: []}
  end

  defmodule DemoApp do
    @behaviour Mob.App
    import Mob.App
    def navigation(_), do: stack(:home, root: MobDeliver.GateNavigationTest.HomeScreen)
  end

  # Answers the watchdog call a release makes, and reports it.
  defmodule FakeWatchdog do
    use GenServer
    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    @impl true
    def init(test_pid), do: {:ok, test_pid}
    @impl true
    def handle_call(:resume_probation, _from, test_pid) do
      send(test_pid, :probation_resumed)
      {:reply, :ok, test_pid}
    end
  end

  # A router that's busy (doesn't answer) for its first `busy` queries.
  defmodule BusyRouter do
    use GenServer
    def start_link(busy), do: GenServer.start_link(__MODULE__, busy)
    @impl true
    def init(busy), do: {:ok, %{busy: busy, current: MobDeliver.GateNavigationTest.HomeScreen}}
    @impl true
    def handle_call(:get_current_module, _from, %{busy: busy} = s) when busy > 0 do
      Process.sleep(150)
      {:reply, s.current, %{s | busy: busy - 1}}
    end

    def handle_call(:get_current_module, _from, s), do: {:reply, s.current, s}

    def handle_call({:navigate, {:reset, dest, _, _, :all}}, _from, s),
      do: {:reply, :ok, %{s | current: dest}}
  end

  setup do
    stop(Process.whereis(Mob.Nav.Registry))
    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    {:ok, router} = Mob.Screen.start_link(HomeScreen, %{})
    Process.unlink(registry)
    Process.unlink(router)
    {:ok, status} = Agent.start_link(fn -> :ok end)
    {:ok, watchdog} = FakeWatchdog.start_link(self())
    GateNavigation.put_root(HomeScreen, HomeScreen, UpdateRequiredScreen)

    on_exit(fn ->
      :persistent_term.erase({MobDeliver, :root})
      stop(router)
      stop(registry)
    end)

    %{router: router, status: status, watchdog: watchdog}
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _already_gone -> :ok
  end

  defp navigation(ctx, extra \\ []) do
    status = ctx.status
    router = Keyword.get(extra, :router, ctx.router)

    start_supervised!(
      {GateNavigation,
       [
         name: :"gate_nav_#{System.unique_integer([:positive])}",
         router: fn -> router end,
         status: fn -> Agent.get(status, & &1) end,
         watchdog: ctx.watchdog
       ] ++ extra}
    )
  end

  defp gate(ctx, status), do: Agent.update(ctx.status, fn _ -> status end)

  defp current(router), do: GenServer.call(router, :get_current_module)

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0, do: fun.(), else: Process.sleep(10) && eventually(fun, tries - 1)
  end

  test "a gate that becomes required replaces the whole navigation with the update screen",
       ctx do
    :ok = GenServer.call(ctx.router, {:navigate, {:push, DetailScreen, %{}}})
    nav = navigation(ctx)

    gate(ctx, {:required, %{}})
    GateNavigation.request(nav)

    assert eventually(fn -> current(ctx.router) == UpdateRequiredScreen end)
    assert Mob.Router.get_nav_history(ctx.router) == []
  end

  test "a gate that opens releases the update screen to the app's root, resuming probation",
       ctx do
    nav = navigation(ctx)
    gate(ctx, {:required, %{}})
    GateNavigation.request(nav)
    assert eventually(fn -> current(ctx.router) == UpdateRequiredScreen end)

    gate(ctx, {:recommended, %{}})
    GateNavigation.request(nav)

    assert eventually(fn -> current(ctx.router) == HomeScreen end)
    assert_receive :probation_resumed
  end

  test "changes are applied in order against the gate as it is now, never a stale one", ctx do
    nav = navigation(ctx)

    # Required, then lifted before anything ran: the user ends up on the root.
    gate(ctx, {:required, %{}})
    GateNavigation.request(nav)
    gate(ctx, :ok)
    GateNavigation.request(nav)

    Process.sleep(100)
    assert current(ctx.router) == HomeScreen
  end

  test "a router too busy to answer is asked again, not given up on", ctx do
    {:ok, busy} = BusyRouter.start_link(2)
    nav = navigation(ctx, router: busy, call_timeout: 50, retry_ms: 20)

    gate(ctx, {:required, %{}})
    GateNavigation.request(nav)

    assert eventually(fn ->
             GenServer.call(busy, :get_current_module, 1_000) == UpdateRequiredScreen
           end)
  end

  test "without a known root the update screen stays, logged", ctx do
    nav = navigation(ctx)
    gate(ctx, {:required, %{}})
    GateNavigation.request(nav)
    assert eventually(fn -> current(ctx.router) == UpdateRequiredScreen end)
    :persistent_term.erase({MobDeliver, :root})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        gate(ctx, :ok)
        GateNavigation.request(nav)
        Process.sleep(100)
      end)

    assert log =~ "MobDeliver.root_screen/2"
    assert current(ctx.router) == UpdateRequiredScreen
  end
end
