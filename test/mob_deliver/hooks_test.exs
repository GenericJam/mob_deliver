defmodule MobDeliver.HooksTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Gate, Hooks, Manifest, Refresh, SingleFlight, Store, TestPublisher, Watchdog}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    n = System.unique_integer([:positive])
    store = :"hooks_store_#{n}"
    sf = :"hooks_sf_#{n}"
    gate = :"hooks_gate_#{n}"
    watchdog = :"hooks_wd_#{n}"
    refresh = :"hooks_refresh_#{n}"
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    start_supervised!({Store, name: store, root: root}, id: store)
    start_supervised!({SingleFlight, name: sf}, id: sf)
    start_supervised!({Gate, name: gate, store: store, verify: verify}, id: gate)

    start_supervised!({Watchdog, name: watchdog, store: store, app_version: "1.4.0"},
      id: watchdog
    )

    start_supervised!({Refresh, name: refresh}, id: refresh)

    ctx = %{store: store, gate: gate, private: private, verify: verify, n: n}
    {manifest_body, _} = signed(ctx, %{})

    # Serves a manifest delivering only MyApp.HomeScreen; every blob is unavailable.
    plug = fn
      %{request_path: "/manifest"} = conn -> Plug.Conn.send_resp(conn, 200, manifest_body)
      conn -> Plug.Conn.send_resp(conn, 503, "")
    end

    opts = [
      store: store,
      single_flight: sf,
      gate: gate,
      watchdog: watchdog,
      refresh: refresh,
      refresh_interval: 60_000,
      app_version: "1.4.0",
      client_opts: [
        endpoint: "https://updates.example.test",
        app: "com.example.app",
        channel: "production",
        trusted_publish_key: key,
        req_options: [plug: plug]
      ]
    ]

    Map.put(ctx, :opts, opts)
  end

  defp signed(ctx, fields) do
    body = fields |> TestPublisher.fields() |> TestPublisher.sign(ctx.private) |> JSON.encode!()
    {:ok, manifest} = ctx.verify.(body)
    {body, manifest}
  end

  test "loaded screens and destinations nobody delivers pass through to the router", ctx do
    {body, manifest} = signed(ctx, %{})
    :ok = Store.activate(ctx.store, body, manifest, nil)

    assert Hooks.before_navigate(Enum, ctx.opts) == :ok
    assert Hooks.before_navigate(:settings_route, ctx.opts) == :ok
    assert Hooks.before_navigate(:"Elixir.MobDeliverHooks#{ctx.n}.Typo", ctx.opts) == :ok
  end

  test "a delivered screen that can't be fetched refuses the navigation, with a warning", ctx do
    key = "MobDeliverHooks#{ctx.n}.Remote"
    {body, manifest} = signed(ctx, %{"modules" => %{key => "sha256:" <> TestPublisher.sha()}})
    :ok = Store.activate(ctx.store, body, manifest, nil)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:http_status, 503}} =
                 Hooks.before_navigate(Manifest.key_module(key), ctx.opts)
      end)

    assert log =~ "mob_deliver: navigation to #{key} refused"
  end

  test "past the forced-update deadline navigation replaces the whole stack with the update screen",
       ctx do
    {body, manifest} =
      signed(ctx, %{"min_app_version" => "2.0", "force_update_after" => "2026-01-01T00:00:00Z"})

    :ok = Gate.record(ctx.gate, body, manifest)

    assert Hooks.before_navigate(Enum, ctx.opts) == {:reset, MobDeliver.UpdateRequiredScreen}

    assert Hooks.before_navigate(MobDeliver.UpdateRequiredScreen, ctx.opts) ==
             {:reset, MobDeliver.UpdateRequiredScreen}
  end

  test "a frame of the update screen doesn't end the booted update's probation and asks for the next frame; the app's own frame does",
       ctx do
    {body, manifest} = signed(ctx, %{})
    {:ok, :installed} = Watchdog.install(ctx.opts[:watchdog], body, manifest, nil)

    # The next launch boots it on probation.
    booted = :"hooks_wd_booted_#{ctx.n}"

    start_supervised!({Watchdog, name: booted, store: ctx.store, app_version: "1.4.0"},
      id: booted
    )

    {:ok, :armed} = Watchdog.on_boot(booted, ctx.verify)
    test_pid = self()

    opts = [
      watchdog: booted,
      update_screen: MobDeliver.UpdateRequiredScreen,
      rearm: fn -> send(test_pid, :rearmed) end,
      reconcile: fn -> :ok end
    ]

    # Whatever root_screen/2 picked: this frame is the update screen's.
    assert Hooks.first_render(MobDeliver.UpdateRequiredScreen, opts) == :ok
    assert_received :rearmed
    refute Watchdog.ready_to_install?(booted)
    refute Watchdog.first_idle?(booted)

    assert Hooks.first_render(MyApp.Home, opts) == :ok
    refute_received :rearmed
    assert Watchdog.ready_to_install?(booted)
    assert Watchdog.first_idle?(booted)
  end
end
