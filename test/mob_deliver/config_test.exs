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
