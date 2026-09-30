defmodule MobDeliver.HooksTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Gate, Hooks, Manifest, SingleFlight, Store, TestPublisher}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    n = System.unique_integer([:positive])
    store = :"hooks_store_#{n}"
    sf = :"hooks_sf_#{n}"
    gate = :"hooks_gate_#{n}"
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    start_supervised!({Store, name: store, root: root}, id: store)
    start_supervised!({SingleFlight, name: sf}, id: sf)
    start_supervised!({Gate, name: gate, store: store, verify: verify}, id: gate)

    plug = fn conn -> Plug.Conn.send_resp(conn, 503, "") end

    opts = [
      store: store,
      single_flight: sf,
      gate: gate,
      app_version: "1.0",
      check: fn -> :ok end,
      client_opts: [endpoint: "https://updates.example.test", req_options: [plug: plug]]
    ]

    %{opts: opts, store: store, gate: gate, private: private, verify: verify, n: n}
  end

  defp signed(ctx, fields) do
    body = fields |> TestPublisher.fields() |> TestPublisher.sign(ctx.private) |> JSON.encode!()
    {:ok, manifest} = ctx.verify.(body)
    {body, manifest}
  end

  test "loaded screens and destinations mob_deliver doesn't deliver pass through", ctx do
    {body, manifest} = signed(ctx, %{})
    :ok = Store.activate(ctx.store, body, manifest, nil)

    assert Hooks.before_navigate(Enum, ctx.opts) == :ok
    assert Hooks.before_navigate(:settings_route, ctx.opts) == :ok
  end

  test "a delivered screen that can't be fetched refuses the navigation", ctx do
    key = "MobDeliverHooks#{ctx.n}.Remote"
    {body, manifest} = signed(ctx, %{"modules" => %{key => "sha256:" <> TestPublisher.sha()}})
    :ok = Store.activate(ctx.store, body, manifest, nil)

    assert {:error, {:http_status, 503}} =
             Hooks.before_navigate(Manifest.key_module(key), ctx.opts)
  end

  test "past the forced-update deadline navigation is redirected to the update screen", ctx do
    {body, manifest} =
      signed(ctx, %{"min_app_version" => "2.0", "force_update_after" => "2026-01-01T00:00:00Z"})

    :ok = Gate.record(ctx.gate, body, manifest)

    assert Hooks.before_navigate(Enum, ctx.opts) == {:redirect, MobDeliver.UpdateRequiredScreen}
  end
end
