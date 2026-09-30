defmodule MobDeliver.UpdateRequiredScreen do
  @moduledoc """
  The hard stop after `force_update_after`: what `MobDeliver.root_screen/2`
  boots into instead of the app's root screen when `MobDeliver.Gate` says
  `:required`, and what navigation is reset to mid-session past the
  deadline. It's the only screen on the navigation stack, so back exits
  the app rather than revealing a user screen. Its button opens
  `config :mob_deliver, :store_url`; without one it tells the user to
  update from their store instead of showing a button that can't work.

  Colours are the active theme's (`:background`, `:on_background`,
  `:muted`), so it's readable in light and dark themes.

  Pass your own screen as `root_screen/2`'s second argument (and
  `config :mob_deliver, :update_screen`) to replace it.
  """

  use Mob.Screen

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, Mob.Socket.assign(socket, :store_url, MobDeliver.Config.get(:store_url))}

  @impl true
  def render(assigns) do
    %{
      type: :column,
      props: %{padding: :space_lg, gap: :space_md, background: :background},
      children:
        [
          text("Update required", %{
            text_size: :xl,
            font_weight: "bold",
            text_color: :on_background
          }),
          text(
            "This version of the app is no longer supported. Update it to keep using it.",
            %{text_color: :on_background}
          )
        ] ++ update_action(assigns.store_url)
    }
  end

  @impl true
  def handle_info({:tap, :open_store}, socket) do
    MobDeliver.open_store()
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp text(text, props), do: %{type: :text, props: Map.put(props, :text, text), children: []}

  defp update_action(nil) do
    [
      text(
        "Open the App Store or Google Play on this device, find this app and tap Update.",
        %{text_color: :muted}
      )
    ]
  end

  defp update_action(_url),
    do: [%{type: :button, props: %{text: "Update", on_tap: {self(), :open_store}}, children: []}]
end
