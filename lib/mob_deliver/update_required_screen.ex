defmodule MobDeliver.UpdateRequiredScreen do
  @moduledoc """
  The hard stop after `force_update_after`: what `MobDeliver.root_screen/2`
  boots into instead of the app's root screen when `MobDeliver.Gate` says
  `:required`. It's the root of its stack, so back exits the app rather
  than revealing a user screen. Its button opens `config :mob_deliver,
  :store_url`.

  Pass your own screen as `root_screen/2`'s second argument to replace it.
  """

  use Mob.Screen

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, Mob.Socket.assign(socket, :store_url, MobDeliver.Config.get(:store_url))}

  @impl true
  def render(assigns) do
    %{
      type: :column,
      props: %{padding: :space_lg, gap: :space_md},
      children:
        [
          text("Update required", %{text_size: :xl, font_weight: "bold"}),
          text(
            "This version of the app is no longer supported. Update it from the store to keep using it.",
            %{}
          )
        ] ++ update_button(assigns.store_url)
    }
  end

  @impl true
  def handle_info({:tap, :open_store}, socket) do
    MobDeliver.open_store()
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp text(text, props), do: %{type: :text, props: Map.put(props, :text, text), children: []}

  defp update_button(nil), do: []

  defp update_button(_url),
    do: [%{type: :button, props: %{text: "Update", on_tap: {self(), :open_store}}, children: []}]
end
