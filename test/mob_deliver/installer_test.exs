defmodule MobDeliver.InstallerTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Gate, Installer, Manifest, SingleFlight, Store, TestPublisher, Watchdog}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    n = System.unique_integer([:positive])
    store = :"inst_store_#{n}"
    sf = :"inst_sf_#{n}"
    watchdog = :"inst_wd_#{n}"
    start_supervised!({Store, name: store, root: root}, id: store)
    start_supervised!({SingleFlight, name: sf}, id: sf)
    start_supervised!({Watchdog, name: watchdog, store: store}, id: watchdog)
    gate = :"inst_gate_#{n}"
    start_supervised!({Gate, name: gate, store: store}, id: gate)
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")

    %{
      root: root,
      key: key,
      private: private,
      verify: verify,
      store: store,
      sf: sf,
      watchdog: watchdog,
      gate: gate,
      n: n
    }
  end

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp body(ctx, modules, private \\ nil, extra \\ %{}) do
    %{"modules" => Map.new(modules, fn {key, bin} -> {key, "sha256:" <> sha(bin)} end)}
    |> Map.merge(extra)
    |> TestPublisher.fields()
    |> TestPublisher.sign(private || ctx.private)
    |> JSON.encode!()
  end

  defp activate!(ctx, b) do
    {:ok, manifest} = ctx.verify.(b)
    :ok = Store.activate(ctx.store, b, manifest, Store.active_id(ctx.store))
  end

  # Installer options against a server publishing `manifest_body` and `blobs`.
  defp opts(ctx, manifest_body, blobs, overrides \\ []) do
    test_pid = self()

    plug = fn
      %{request_path: "/manifest"} = conn ->
        Plug.Conn.send_resp(conn, 200, manifest_body)

      %{request_path: "/beam/" <> requested} = conn ->
        send(test_pid, {:fetched, requested})

        case Map.fetch(blobs, requested) do
          {:ok, bytes} -> Plug.Conn.send_resp(conn, 200, bytes)
          :error -> Plug.Conn.send_resp(conn, 404, "")
        end
    end

    [
      store: ctx.store,
      watchdog: ctx.watchdog,
      gate: ctx.gate,
      app_version: "2.0.0",
      single_flight: ctx.sf,
      client_opts: [
        endpoint: "https://updates.example.test",
        app: "com.example.app",
        channel: "production",
        trusted_publish_key: ctx.key,
        req_options: [plug: plug]
      ]
    ]
    |> Keyword.merge(overrides)
  end

  test "installs a new manifest, prefetching new versions of what the device runs", ctx do
    new_screen = "MobDeliverInstall#{ctx.n}.NeverSeen"
    activate!(ctx, body(ctx, [{"MyApp.Home", "home v1"}]))

    update =
      body(ctx, [
        # changed and already delivered → prefetch
        {"MyApp.Home", "home v2"},
        # bundled (on the code path) → prefetch
        {"Enum", "enum v2"},
        # never on this device → left for resolve/1
        {new_screen, "new screen"}
      ])

    blobs = Map.new(["home v2", "enum v2", "new screen"], &{sha(&1), &1})

    assert Installer.check(opts(ctx, update, blobs)) == {:ok, :installed}
    assert Store.active_id(ctx.store) == Store.manifest_id(update)
    assert Store.has_blob?(ctx.store, sha("home v2"))
    assert Store.has_blob?(ctx.store, sha("enum v2"))
    refute Store.has_blob?(ctx.store, sha("new screen"))

    assert Installer.check(opts(ctx, update, blobs)) == {:ok, :current}
  end

  test "a prefetch failure installs nothing", ctx do
    current = body(ctx, [{"MyApp.Home", "home v1"}])
    activate!(ctx, current)
    update = body(ctx, [{"MyApp.Home", "home v2"}])

    assert {:error, {:prefetch_failed, _sha, {:http_status, 404}}} =
             Installer.check(opts(ctx, update, %{}))

    assert Store.active_id(ctx.store) == Store.manifest_id(current)
  end

  test "a manifest this device rolled back before is never reinstalled", ctx do
    update = body(ctx, [{"MyApp.Home", "bad"}])

    File.mkdir_p!(ctx.root)

    File.write!(
      Path.join(ctx.root, "watchdog"),
      :erlang.term_to_binary(%{
        armed: nil,
        boots: 0,
        rejected: [Store.manifest_id(update)],
        notice: nil
      })
    )

    assert Installer.check(opts(ctx, update, %{sha("bad") => "bad"})) == {:ok, :rejected}
    assert Store.active_id(ctx.store) == nil
  end

  test "an install waits while the booted update is on probation", ctx do
    probation = body(ctx, [{"MyApp.Home", "p"}])
    {:ok, manifest} = ctx.verify.(probation)
    {:ok, :installed} = Watchdog.install(ctx.watchdog, probation, manifest, nil)

    # Next launch boots it on probation.
    booted = :"#{ctx.watchdog}_booted"
    start_supervised!({Watchdog, name: booted, store: ctx.store}, id: booted)
    {:ok, :armed} = Watchdog.on_boot(booted, ctx.verify)

    update = body(ctx, [{"MyApp.Home", "next"}])
    blobs = %{sha("next") => "next"}

    assert Installer.check(opts(ctx, update, blobs, watchdog: booted)) == {:ok, :deferred}
    assert Store.active_id(ctx.store) == Store.manifest_id(probation)

    Watchdog.mark_stable(booted)
    assert Installer.check(opts(ctx, update, blobs, watchdog: booted)) == {:ok, :installed}
  end

  test "a manifest not signed by this build's key is refused", ctx do
    {_other, other_private} = TestPublisher.keypair()
    forged = body(ctx, [{"MyApp.Home", "evil"}], other_private)

    assert Installer.check(opts(ctx, forged, %{})) == {:error, :invalid_signature}
    assert Store.active_id(ctx.store) == nil
  end

  test "a manifest this app version is below the floor of isn't installed, but gates the app",
       ctx do
    floor =
      body(ctx, [{"MyApp.Home", "v9"}], nil, %{
        "min_app_version" => "9.0",
        "force_update_after" => "2026-10-19T00:00:00Z"
      })

    assert Installer.check(opts(ctx, floor, %{sha("v9") => "v9"})) == {:ok, :below_min_version}
    assert Store.active_id(ctx.store) == nil

    assert {:required, _} =
             Gate.status(ctx.gate, app_version: "2.0.0", now: ~U[2026-11-01 00:00:00Z])
  end

  test "delivered helpers that a prefetched boot module calls are prefetched too", ctx do
    n = ctx.n

    compile = fn source ->
      {[{module, binary}], _} =
        Code.with_diagnostics([log: false], fn -> Code.compile_string(source) end)

      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      {module, binary}
    end

    {helper, helper_bin} =
      compile.("defmodule MobDeliverInstall#{n}.Helper do def ready, do: :ok end")

    {boot_mod, old_bin} = compile.("defmodule MobDeliverInstall#{n}.Boot do def v, do: 1 end")

    {^boot_mod, new_bin} =
      compile.(
        "defmodule MobDeliverInstall#{n}.Boot do def v, do: #{inspect(helper)}.ready() end"
      )

    boot_key = Manifest.module_key(boot_mod)
    helper_key = Manifest.module_key(helper)

    activate!(ctx, body(ctx, [{boot_key, old_bin}]))
    update = body(ctx, [{boot_key, new_bin}, {helper_key, helper_bin}])
    blobs = %{sha(new_bin) => new_bin, sha(helper_bin) => helper_bin}

    assert Installer.check(opts(ctx, update, blobs)) == {:ok, :installed}
    assert Store.has_blob?(ctx.store, sha(helper_bin))
  end

  test "keys of modules this device has never heard of don't create atoms", ctx do
    unheard_of = "MobDeliverUnheardOf#{System.unique_integer([:positive])}xyz.Screen"
    update = body(ctx, [{unheard_of, "bytes"}])

    assert Installer.check(opts(ctx, update, %{sha("bytes") => "bytes"})) == {:ok, :installed}
    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> unheard_of) end
  end
end
