defmodule MobDeliver.SelfTestTest do
  # Stops and restarts the :mob_deliver application: not async.
  use ExUnit.Case, async: false

  alias MobDeliver.Store
  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../..", __DIR__)
  @ctx %{platform: :ios, device: :simulator}

  setup do
    on_exit(fn -> {:ok, _} = Application.ensure_all_started(:mob_deliver) end)
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobDeliver.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "passes against the running application and leaves no blob behind" do
    before = Path.wildcard(Path.join(Store.root(Store), "blobs/*"))

    assert MobDeliver.SelfTest.run(@ctx) == :pass
    assert Path.wildcard(Path.join(Store.root(Store), "blobs/*")) == before
  end

  test "fails, naming the cause, when the application is not running" do
    :ok = Application.stop(:mob_deliver)

    assert {:fail, reason} = MobDeliver.SelfTest.run(@ctx)
    assert reason =~ ":mob_deliver application is not running"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end
end
