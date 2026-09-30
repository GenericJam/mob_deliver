defmodule MobDeliver.UpdateRequiredScreenTest do
  # Mob.ScreenCase starts the shared Mob.State; not async.
  use Mob.ScreenCase

  alias MobDeliver.UpdateRequiredScreen

  setup do
    previous = Application.get_env(:mob_deliver, :store_url)
    on_exit(fn -> Application.put_env(:mob_deliver, :store_url, previous) end)
  end

  test "tells the user to update, with a store button only when there's a store URL" do
    Application.put_env(:mob_deliver, :store_url, "https://apps.apple.com/app/id1")
    view = mount_screen(UpdateRequiredScreen)

    assert text(view) =~ "Update required"
    assert find(view, :button)
    assert_renderable(view)

    Application.delete_env(:mob_deliver, :store_url)
    view = mount_screen(UpdateRequiredScreen)
    refute find(view, :button)
    assert text(view) =~ "App Store or Google Play"
    assert_renderable(view)
  end

  test "every text is readable on the screen's background in dark and light themes" do
    Application.delete_env(:mob_deliver, :store_url)
    tree = UpdateRequiredScreen |> mount_screen() |> tree()

    for theme <- [Mob.Theme.Dark.theme(), Mob.Theme.Light.theme()] do
      background = argb(theme, tree.props[:background])
      assert is_integer(background)

      for %{type: :text, props: props} <- flatten(tree) do
        text = argb(theme, props[:text_color])
        assert is_integer(text), "#{inspect(props.text)} has no theme colour"
        assert text != background, "#{inspect(props.text)} is invisible"
      end
    end
  end

  # A colour token through the theme's semantic map, then the base palette.
  defp argb(theme, token) do
    colors = Mob.Theme.color_map(theme)
    palette = Mob.Renderer.colors()
    resolved = Map.get(colors, token, token)
    if is_integer(resolved), do: resolved, else: Map.get(palette, resolved)
  end
end
