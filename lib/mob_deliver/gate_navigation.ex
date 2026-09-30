defmodule MobDeliver.GateNavigation do
  @moduledoc false
  # Keeps what's on screen in step with the forced-update gate mid-session:
  #
  #   * the gate became :required and a user screen is showing → replace all
  #     navigation with the update screen (N6: before, only the next
  #     navigation did);
  #   * the gate opened and the update screen is showing → replace it with
  #     the app's root, the screen MobDeliver.root_screen/2 was asked for (N5).
  #
  # Runs when the gate changes (MobDeliver.Gate's :on_change) and at the
  # root screen's first frame (a change that landed before the router
  # existed). Navigation goes through the router's normal path, so mob_deliver's
  # :before_navigate hook still has the last word. Never call it from the
  # router or the gate process: the router calls the hook, the hook reads
  # the gate. `run/0` spawns it.

  require Logger

  alias MobDeliver.{Config, Gate}

  @root {MobDeliver, :root}

  @doc "Reconciles in a separate process (never blocks or raises); options as for `reconcile/1`."
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    spawn(fn -> reconcile(opts) end)
    :ok
  end

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

  @doc """
  Options (for tests): `:router` (default the app's router, `:mob_screen`),
  `:status` (default `MobDeliver.Gate.status/0`), `:root` (default the
  recorded requested root), `:update_screen`.
  """
  @spec reconcile(keyword()) :: :locked | :released | :noop
  def reconcile(opts \\ []) do
    router = Keyword.get_lazy(opts, :router, fn -> Process.whereis(:mob_screen) end)
    update_screen = Keyword.get_lazy(opts, :update_screen, &update_screen/0)

    if router do
      status = Keyword.get_lazy(opts, :status, &Gate.status/0)
      root = Keyword.get_lazy(opts, :root, fn -> root_requested() end)
      apply_gate(router, status, Mob.Router.get_current_module(router), update_screen, root)
    else
      :noop
    end
  catch
    kind, reason ->
      Logger.warning(
        "mob_deliver: couldn't apply the update gate to navigation (#{Exception.format_banner(kind, reason)})"
      )

      :noop
  end

  defp apply_gate(router, {:required, _}, current, update_screen, _root)
       when current != update_screen do
    Logger.warning(
      "mob_deliver: this app version is past its forced-update deadline; showing #{inspect(update_screen)}"
    )

    reset(router, update_screen)
    :locked
  end

  defp apply_gate(_router, {:required, _}, _current, _update_screen, _root), do: :noop

  defp apply_gate(_router, _open, current, update_screen, _root) when current != update_screen,
    do: :noop

  defp apply_gate(_router, _open, _current, _update_screen, nil) do
    Logger.warning(
      "mob_deliver: the update gate is open again, but the app's root screen is unknown " <>
        "(boot through MobDeliver.root_screen/2); the update screen stays until the next launch"
    )

    :noop
  end

  defp apply_gate(router, _open, _current, _update_screen, root) do
    Logger.info("mob_deliver: the update gate is open again; back to #{inspect(root)}")
    reset(router, root)
    :released
  end

  defp reset(router, screen),
    do: GenServer.call(router, {:navigate, {:reset, screen, %{}, :reset, :all}}, 30_000)

  defp root_requested do
    case root() do
      %{requested: requested} -> requested
      nil -> nil
    end
  end

  @doc "The update screen: the one given to `MobDeliver.root_screen/2`, else `:update_screen` config, else the default."
  @spec update_screen() :: module()
  def update_screen do
    case root() do
      %{update_screen: screen} -> screen
      nil -> Config.get(:update_screen) || MobDeliver.UpdateRequiredScreen
    end
  end
end
