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

  @required {:required, %{}}

  setup do
    stop(Process.whereis(Mob.Nav.Registry))
    {:ok, registry} = Mob.Nav.Registry.start_link(DemoApp)
    {:ok, router} = Mob.Screen.start_link(HomeScreen, %{})
    Process.unlink(registry)
    Process.unlink(router)

    on_exit(fn ->
      stop(router)
      stop(registry)
    end)

    %{router: router}
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _already_gone -> :ok
  end

  defp current(router), do: Mob.Router.get_current_module(router)

  defp push(router, screen),
    do: :ok = GenServer.call(router, {:navigate, {:push, screen, %{}}})

  test "a gate that becomes required replaces the whole navigation with the update screen",
       %{router: router} do
    push(router, DetailScreen)

    assert GateNavigation.reconcile(router: router, status: @required, root: HomeScreen) ==
             :locked

    assert current(router) == UpdateRequiredScreen
    assert Mob.Router.get_nav_history(router) == []
  end

  test "a gate that opens releases the update screen to the app's root", %{router: router} do
    GateNavigation.reconcile(router: router, status: @required, root: HomeScreen)

    assert GateNavigation.reconcile(router: router, status: :ok, root: HomeScreen) == :released
    assert current(router) == HomeScreen
    assert Mob.Router.get_nav_history(router) == []

    GateNavigation.reconcile(router: router, status: @required, root: HomeScreen)

    assert GateNavigation.reconcile(router: router, status: {:recommended, %{}}, root: HomeScreen) ==
             :released
  end

  test "navigation that already matches the gate is left alone", %{router: router} do
    push(router, DetailScreen)

    assert GateNavigation.reconcile(router: router, status: :ok, root: HomeScreen) == :noop
    assert current(router) == DetailScreen

    GateNavigation.reconcile(router: router, status: @required, root: HomeScreen)
    assert GateNavigation.reconcile(router: router, status: @required, root: HomeScreen) == :noop
  end

  test "without a known root the update screen stays, logged", %{router: router} do
    GateNavigation.reconcile(router: router, status: @required, root: HomeScreen)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert GateNavigation.reconcile(router: router, status: :ok, root: nil) == :noop
      end)

    assert log =~ "MobDeliver.root_screen/2"
    assert current(router) == UpdateRequiredScreen
  end

  test "without a router (before the root screen starts) nothing happens" do
    assert GateNavigation.reconcile(router: nil, status: @required, root: HomeScreen) == :noop
  end
end
