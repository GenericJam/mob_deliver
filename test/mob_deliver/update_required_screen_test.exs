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
    refute UpdateRequiredScreen |> mount_screen() |> find(:button)
  end
end
