defmodule MobDeliver.ConfigTest do
  # Changes the :mob_deliver application env: not async.
  use ExUnit.Case, async: false

  alias MobDeliver.{Boot, Manifest, Store, TestPublisher, Watchdog}

  @moduletag :capture_log
  @moduletag :tmp_dir

  @keys [:trusted_publish_key, :endpoint, :app, :channel, :req_options]

  setup do
    previous = for key <- @keys, do: {key, Application.fetch_env(:mob_deliver, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:mob_deliver, key, value)
          :error -> Application.delete_env(:mob_deliver, key)
        end
      end
    end)
  end

  defp configure(key) do
    Application.put_all_env(
      mob_deliver: [
        trusted_publish_key: key,
        endpoint: "https://updates.example.test",
        app: "com.example.app",
        channel: :production,
        req_options: [plug: {Req.Test, __MODULE__}]
      ]
    )
  end

  test "the trusted key is read when it's used, so config changes need no recompile" do
    {key, private} = TestPublisher.keypair()
    body = TestPublisher.fields() |> TestPublisher.sign(private) |> JSON.encode!()
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))

    {other_key, _} = TestPublisher.keypair()
    configure(other_key)
    assert MobDeliver.fetch_manifest() == {:error, :invalid_signature}

    configure(key)
    assert {:ok, %Manifest{app: "com.example.app"}} = MobDeliver.fetch_manifest()
  end

  describe "with the build's config module (as on a device)" do
    setup do
      on_exit(fn ->
        for _ <- 1..2, do: :code.purge(:mob_app_config)
        :code.delete(:mob_app_config)
        :code.purge(:mob_app_config)
      end)
    end

    # What mob_dev generates: the app's config/*.exs, evaluated at build time.
    defp build_config(entries) do
      {:module, :mob_app_config, binary, _} =
        Module.create(
          :mob_app_config,
          quote(do: def(config, do: unquote(Macro.escape(entries)))),
          Macro.Env.location(__ENV__)
        )

      binary
    end

    test "the trusted key, app, channel and app version come from the build and can't be changed at runtime" do
      {key, private} = TestPublisher.keypair()
      {attacker_key, attacker_private} = TestPublisher.keypair()

      build_config(
        mob_deliver: [
          trusted_publish_key: key,
          app: "com.example.app",
          channel: :production,
          app_version: "2.0.0"
        ]
      )

      configure(key)

      # Something running in the app tries to swap the trust root.
      Application.put_env(:mob_deliver, :trusted_publish_key, attacker_key)
      Application.put_env(:mob_deliver, :app, "com.attacker.app")
      Application.put_env(:mob_deliver, :app_version, "99.0.0")
      on_exit(fn -> Application.delete_env(:mob_deliver, :app_version) end)

      assert MobDeliver.Config.app_version() == "2.0.0"

      forged = TestPublisher.fields() |> TestPublisher.sign(attacker_private) |> JSON.encode!()
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, forged))
      assert MobDeliver.fetch_manifest() == {:error, :invalid_signature}

      genuine = TestPublisher.fields() |> TestPublisher.sign(private) |> JSON.encode!()
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, genuine))
      assert {:ok, %Manifest{app: "com.example.app"}} = MobDeliver.fetch_manifest()
    end

    test "a build without a key is not configured, whatever the runtime environment says" do
      build_config(mob_deliver: [app: "com.example.app", channel: :production])
      {key, _} = TestPublisher.keypair()
      configure(key)

      assert :trusted_publish_key in MobDeliver.Config.missing()
    end
  end

  test "a malformed trusted key at boot leaves the stored manifests alone and says what to fix",
       %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    body = TestPublisher.fields() |> TestPublisher.sign(private) |> JSON.encode!()
    {:ok, manifest} = verify.(body)

    n = System.unique_integer([:positive])
    store = :"cfg_store_#{n}"
    start_supervised!({Store, name: store, root: root}, id: store)
    :ok = Store.activate(store, body, manifest, nil)

    configure("ed25519:not-a-key")
    booted = :"cfg_store_booted_#{n}"
    watchdog = :"cfg_wd_#{n}"
    start_supervised!({Store, name: booted, root: root}, id: booted)
    start_supervised!({Watchdog, name: watchdog, store: booted}, id: watchdog)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Boot.run(store: booted, watchdog: watchdog, poller: nil) == :ok
      end)

    assert log =~ "trusted_publish_key"
    assert log =~ "isn't a valid"

    # With the key fixed, the stored manifest is still there.
    configure(key)
    again = :"cfg_store_again_#{n}"
    start_supervised!({Store, name: again, root: root}, id: again)
    assert {:ok, %Manifest{}} = Store.boot(again, verify)
  end
end
