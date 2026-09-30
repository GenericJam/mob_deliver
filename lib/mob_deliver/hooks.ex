defmodule MobDeliver.Hooks do
  @moduledoc """
  mob_deliver's side of `Mob.Router.Hooks`, registered by the plugin's
  `on_start`.

    * `:before_navigate` — every push/reset goes through `MobDeliver.resolve/1`
      first: a delivered screen not on the device yet is fetched (after a
      manifest refresh if it was published after the last install). Past
      the forced-update deadline the navigation instead **replaces the
      whole navigation** with the update screen (`config :mob_deliver,
      :update_screen`, default `MobDeliver.UpdateRequiredScreen`), so back
      can't return to a user screen. Route atoms and anything mob_deliver
      doesn't deliver pass through to the router unchanged (an unknown
      module gets the router's usual "unknown navigation destination"
      error). A failed fetch refuses the navigation: the user stays on the
      current screen and a `mob_deliver:` warning is logged.
    * `:after_first_render` — the root screen has painted: first idle, so
      the booted update's probation ends (`MobDeliver.mark_stable/0`).

  Fetching runs in the router process: navigation to a screen that isn't
  on the device yet waits for its download, and nothing else navigates
  meanwhile. To show progress or a "couldn't load" message instead, call
  `MobDeliver.resolve/1` yourself off the screen process before
  navigating (see its docs).
  """

  require Logger

  @doc "Registers both hooks."
  @spec register() :: :ok
  def register do
    Mob.Router.Hooks.register(:before_navigate, {__MODULE__, :before_navigate, []})
    Mob.Router.Hooks.register(:after_first_render, {__MODULE__, :first_render, []})
  end

  @doc false
  @spec before_navigate(atom(), keyword()) :: :ok | {:reset, module()} | {:error, term()}
  def before_navigate(dest, resolver_opts \\ []) do
    case MobDeliver.Resolver.resolve(dest, resolver_opts) do
      :ok ->
        :ok

      {:error, :update_required} ->
        {:reset, MobDeliver.GateNavigation.update_screen()}

      {:error, :not_found} ->
        :ok

      {:error, reason} = refused ->
        Logger.warning(
          "mob_deliver: navigation to #{inspect(dest)} refused, it couldn't be delivered (#{inspect(reason)})"
        )

        refused
    end
  end

  @doc false
  # The root screen's first frame. If it was the update screen (the app
  # booted under a required gate), none of the booted update's screens ran:
  # that's first idle without proof. Then bring navigation in line with the
  # gate, which may have changed before the router existed.
  @spec first_render(keyword()) :: :ok | {:error, term()}
  def first_render(opts \\ []) do
    watchdog = Keyword.get(opts, :watchdog, MobDeliver.Watchdog)
    root = Keyword.get_lazy(opts, :root, &MobDeliver.GateNavigation.root/0)
    reconcile = Keyword.get(opts, :reconcile, &MobDeliver.GateNavigation.run/0)

    result =
      case root do
        %{booted: booted, requested: requested} when booted != requested ->
          MobDeliver.Watchdog.mark_idle_unproven(watchdog)

        _ ->
          MobDeliver.Watchdog.mark_stable(watchdog)
      end

    reconcile.()
    result
  end
end
