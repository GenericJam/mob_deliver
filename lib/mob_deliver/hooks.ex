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
  # A committed frame of `screen` (mob calls this for the VM's first frame,
  # and again for the next one each time it's re-armed). The update screen's
  # frame proves nothing: none of the booted update's screens ran. Then the
  # hook is re-armed so the next frame — eventually the app's, once the gate
  # lets it through — is judged too. Any other screen's frame is first idle.
  # `nil` (mob couldn't tell, mid hot code push) proves nothing either.
  # Either way navigation is brought in line with the gate, which may have
  # changed before the router existed.
  @spec first_render(module() | nil, keyword()) :: :ok | {:error, term()}
  def first_render(screen, opts \\ []) do
    watchdog = Keyword.get(opts, :watchdog, MobDeliver.Watchdog)

    update_screen =
      Keyword.get_lazy(opts, :update_screen, &MobDeliver.GateNavigation.update_screen/0)

    rearm = Keyword.get(opts, :rearm, &Mob.Router.Hooks.rearm_first_render/0)
    reconcile = Keyword.get(opts, :reconcile, &MobDeliver.GateNavigation.request/0)

    result =
      cond do
        screen == update_screen ->
          result = MobDeliver.Watchdog.mark_idle_unproven(watchdog)
          rearm.()
          result

        screen == nil ->
          rearm.()
          :ok

        true ->
          MobDeliver.Watchdog.mark_stable(watchdog)
      end

    reconcile.()
    result
  end
end
