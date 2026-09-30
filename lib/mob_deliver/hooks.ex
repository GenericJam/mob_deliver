defmodule MobDeliver.Hooks do
  @moduledoc """
  mob_deliver's side of `Mob.Router.Hooks` (mob with router hooks; older mob
  falls back to calling `MobDeliver.resolve/1` and `mark_stable/0` from the
  app, see the README).

    * `:before_navigate` — every push/reset goes through `MobDeliver.resolve/1`
      first: a delivered screen not on the device yet is fetched, and past
      the forced-update deadline navigation is redirected to the update
      screen (`config :mob_deliver, :update_screen`, default
      `MobDeliver.UpdateRequiredScreen`). Route atoms and anything
      mob_deliver doesn't deliver pass through to the router unchanged. A
      failed fetch refuses the navigation (the user stays put).
    * `:after_first_render` — the root screen has painted: first idle, so
      the booted update's probation ends (`MobDeliver.mark_stable/0`).

  Fetching runs in the router process: navigation to a screen that isn't
  on the device yet waits for its download.
  """

  @router_hooks Mob.Router.Hooks

  @doc "Registers both hooks if this mob has router hooks. Returns whether it did."
  @spec register() :: boolean()
  def register do
    if Code.ensure_loaded?(@router_hooks) and function_exported?(@router_hooks, :register, 2) do
      # Called dynamically: router hooks are newer than the mob this compiles against.
      apply(@router_hooks, :register, [:before_navigate, {__MODULE__, :before_navigate, []}])
      apply(@router_hooks, :register, [:after_first_render, {__MODULE__, :first_render, []}])
      true
    else
      false
    end
  end

  @doc false
  @spec before_navigate(atom(), keyword()) :: :ok | {:redirect, module()} | {:error, term()}
  def before_navigate(dest, resolver_opts \\ []) do
    case MobDeliver.Resolver.resolve(dest, resolver_opts) do
      :ok ->
        :ok

      {:error, :update_required} ->
        {:redirect, MobDeliver.Config.get(:update_screen) || MobDeliver.UpdateRequiredScreen}

      {:error, :not_found} ->
        :ok

      {:error, _} = refused ->
        refused
    end
  end

  @doc false
  @spec first_render() :: :ok | {:error, term()}
  def first_render, do: MobDeliver.mark_stable()
end
