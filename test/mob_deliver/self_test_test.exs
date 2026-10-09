defmodule MobDeliver.SelfTestTest do
  # Stops and restarts the :mob_deliver application: not async.
  use ExUnit.Case, async: false

  alias MobDeliver.Store
  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../..", __DIR__)
  @ctx %{platform: :ios, device: :simulator}
  @config [endpoint: nil, app: nil, channel: nil, trusted_publish_key: nil]

  setup do
    saved = Enum.map(@config, fn {k, _} -> {k, Application.get_env(:mob_deliver, k)} end)

    on_exit(fn ->
      Enum.each(saved, fn {k, v} -> Application.put_env(:mob_deliver, k, v) end)
      {:ok, _} = Application.ensure_all_started(:mob_deliver)
    end)

    {key, _} = MobDeliver.TestPublisher.keypair()
    Application.put_env(:mob_deliver, :endpoint, "https://deliver.example.com")
    Application.put_env(:mob_deliver, :app, "com.example.app")
    Application.put_env(:mob_deliver, :channel, "production")
    Application.put_env(:mob_deliver, :trusted_publish_key, key)
    :ok
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobDeliver.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "passes against the running, configured application and leaves nothing behind" do
    before = Path.wildcard(Path.join(Store.root(Store), "*"))

    assert MobDeliver.SelfTest.run(@ctx) == :pass
    assert Path.wildcard(Path.join(Store.root(Store), "*")) == before
  end

  test "fails when the store cannot be written" do
    root = Store.root(Store)
    File.mkdir_p!(root)
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod!(root, 0o700) end)

    assert {:fail, reason} = MobDeliver.SelfTest.run(@ctx)
    assert reason =~ "could not start a store" or reason =~ "store round trip"
  end

  test "skips, naming the missing keys, when the plugin is not configured" do
    Application.delete_env(:mob_deliver, :app)
    assert {:skip, reason} = MobDeliver.SelfTest.run(@ctx)
    assert reason =~ "not configured on this host: :app unset"
  end

  test "fails when the configured publish key is not a key (the plugin skips its boot)" do
    Application.put_env(:mob_deliver, :trusted_publish_key, "not-a-key")
    assert {:fail, reason} = MobDeliver.SelfTest.run(@ctx)
    assert reason =~ "trusted_publish_key is not a valid ed25519 key"
  end

  test "fails, naming the cause, when the application is not running" do
    :ok = Application.stop(:mob_deliver)

    assert {:fail, reason} = MobDeliver.SelfTest.run(@ctx)
    assert reason =~ ":mob_deliver application is not running"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end
end
