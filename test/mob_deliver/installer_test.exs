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

    start_supervised!({Watchdog, name: watchdog, store: store, app_version: "2.0.0"},
      id: watchdog
    )

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
        {"Plug.Conn", "conn v2"},
        # never on this device → left for resolve/1
        {new_screen, "new screen"}
      ])

    blobs = Map.new(["home v2", "conn v2", "new screen"], &{sha(&1), &1})

    assert Installer.check(opts(ctx, update, blobs)) == {:ok, :installed}
    assert Store.active_id(ctx.store) == Store.manifest_id(update)
    assert Store.has_blob?(ctx.store, sha("home v2"))
    assert Store.has_blob?(ctx.store, sha("conn v2"))
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

  test "the same modules re-published after a rollback aren't downloaded or reinstalled", ctx do
    rolled_back = body(ctx, [{"MyApp.Home", "bad"}])
    {:ok, manifest} = ctx.verify.(rolled_back)
    File.mkdir_p!(ctx.root)

    File.write!(
      Path.join(ctx.root, "watchdog"),
      :erlang.term_to_binary(%{
        armed: nil,
        boots: 0,
        rejected: [],
        rejections: [
          %{suspects: manifest.modules, app_version: "2.0.0", id: Store.manifest_id(rolled_back)}
        ],
        notice: nil
      })
    )

    republished =
      body(ctx, [{"MyApp.Home", "bad"}], nil, %{"issued_at" => "2026-09-30T20:46:35Z"})

    assert Installer.check(opts(ctx, republished, %{sha("bad") => "bad"})) == {:ok, :rejected}
    assert Store.active_id(ctx.store) == nil
    refute_received {:fetched, _}
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

  test "delivered modules that code running on the device calls are prefetched; ones it only names aren't",
       ctx do
    n = ctx.n
    called = :"Elixir.MobDeliverInstall#{n}.Greeting"
    named = :"Elixir.MobDeliverInstall#{n}.LaterScreen"

    # A bundled screen, loaded from a .beam file as on a device: it calls
    # Greeting and only mentions LaterScreen (e.g. push_screen(socket, it)).
    {:module, _, bundled_bin, _} =
      Module.create(
        :"Elixir.MobDeliverInstall#{n}.HomeScreen",
        quote do
          def text, do: unquote(called).text()
          def next, do: unquote(named)
        end,
        Macro.Env.location(__ENV__)
      )

    dir = Path.join(ctx.root, "bundled")
    File.mkdir_p!(dir)
    base = Path.join(dir, "Elixir.MobDeliverInstall#{n}.HomeScreen")
    File.write!(base <> ".beam", bundled_bin)
    :code.purge(:"Elixir.MobDeliverInstall#{n}.HomeScreen")
    {:module, _} = :code.load_abs(String.to_charlist(base))

    update =
      body(ctx, [
        {Manifest.module_key(called), "greeting"},
        {Manifest.module_key(named), "later screen"}
      ])

    blobs = %{sha("greeting") => "greeting", sha("later screen") => "later screen"}

    assert Installer.check(opts(ctx, update, blobs)) == {:ok, :installed}
    assert Store.has_blob?(ctx.store, sha("greeting"))
    refute Store.has_blob?(ctx.store, sha("later screen"))
  end

  test "a helper newly delivered to a delivered caller loaded from the store is prefetched",
       ctx do
    n = ctx.n
    helper = :"Elixir.MobDeliverInstall#{n}.NewHelper"

    {:module, caller, caller_bin, _} =
      Module.create(
        :"Elixir.MobDeliverInstall#{n}.StoredCaller",
        quote(do: def(run, do: unquote(helper).go())),
        Macro.Env.location(__ENV__)
      )

    # Delivered and loaded as on a device: from blobs/<sha>, no .beam suffix.
    active = body(ctx, [{Manifest.module_key(caller), caller_bin}])
    activate!(ctx, active)
    :ok = Store.put_blob(ctx.store, sha(caller_bin), caller_bin)
    :code.purge(caller)
    path = Store.blob_path(ctx.store, sha(caller_bin))
    {:module, ^caller} = :code.load_binary(caller, String.to_charlist(path), caller_bin)

    # Next release: the caller is unchanged, the helper is new.
    update =
      body(ctx, [
        {Manifest.module_key(caller), caller_bin},
        {Manifest.module_key(helper), "helper"}
      ])

    blobs = %{sha(caller_bin) => caller_bin, sha("helper") => "helper"}

    assert Installer.check(opts(ctx, update, blobs)) == {:ok, :installed}
    assert Store.has_blob?(ctx.store, sha("helper"))
  end

  # One launch over the same store: a fresh watchdog that boots and records
  # what that launch loads.
  defp launch(ctx, loads) do
    name = :"inst_wd_launch_#{System.unique_integer([:positive])}"
    start_supervised!({Watchdog, name: name, store: ctx.store, app_version: "2.0.0"}, id: name)
    outcome = Watchdog.on_boot(name, ctx.verify)
    :ok = Watchdog.note_loaded(name, loads)
    {name, outcome}
  end

  test "screens fetched in earlier sessions don't shield a broken module that a failed update shipped",
       ctx do
    keys = ["MyApp.Home", "MyApp.Greeting", "MyApp.LateScreen", "MyApp.Late2Screen"]
    [home, greeting, late, late2] = keys
    activate!(ctx, body(ctx, [{home, "home"}, {greeting, "greeting 1"}]))

    # An earlier, proven session fetched and ran the late screens.
    for bytes <- ["late 1", "late2 1"], do: :ok = Store.put_blob(ctx.store, sha(bytes), bytes)

    v6 = [{home, "home"}, {greeting, "broken"}, {late, "late 1"}, {late2, "late2 1"}]

    blobs =
      Map.new(["home", "broken", "greeting 2", "late 1", "late 2", "late2 1"], &{sha(&1), &1})

    assert Installer.check(opts(ctx, body(ctx, v6), blobs)) == {:ok, :installed}

    # The probation launch loads everything local and dies on Greeting.
    {_, {:ok, :armed}} = launch(ctx, Map.new(v6, fn {k, b} -> {k, sha(b)} end))
    {next, {:ok, :rolled_back}} = launch(ctx, %{})

    # The device run's follow-up: only LateScreen edited.
    v7 = body(ctx, [{home, "home"}, {greeting, "broken"}, {late, "late 2"}, {late2, "late2 1"}])
    assert Installer.check(opts(ctx, v7, blobs, watchdog: next)) == {:ok, :rejected}

    fixed =
      body(ctx, [{home, "home"}, {greeting, "greeting 2"}, {late, "late 2"}, {late2, "late2 1"}])

    assert Installer.check(opts(ctx, fixed, blobs, watchdog: next)) == {:ok, :installed}
  end

  test "a manifest that only moves the update window is active at once, and doesn't hold up the next update",
       ctx do
    active = body(ctx, [{"MyApp.Home", "home"}])
    activate!(ctx, active)
    blobs = %{sha("home") => "home", sha("home 2") => "home 2"}

    window =
      body(ctx, [{"MyApp.Home", "home"}], nil, %{
        "issued_at" => "2026-09-30T00:00:00Z",
        "min_app_version" => "1.0"
      })

    assert Installer.check(opts(ctx, window, blobs)) == {:ok, :installed}
    assert Store.active_id(ctx.store) == Store.manifest_id(window)

    update = body(ctx, [{"MyApp.Home", "home 2"}], nil, %{"issued_at" => "2026-10-01T00:00:00Z"})
    assert Installer.check(opts(ctx, update, blobs)) == {:ok, :installed}
  end

  test "a manifest that would replace mob_deliver's, mob's or the app config's own code isn't installed",
       ctx do
    for key <- ["MobDeliver.Config", "Mob.App", ":mob_app_config", "JSON"] do
      update = body(ctx, [{"MyApp.Home", "home"}, {key, "replacement"}])
      blobs = %{sha("home") => "home", sha("replacement") => "replacement"}

      assert Installer.check(opts(ctx, update, blobs)) == {:error, {:protected_modules, [key]}}
      assert Store.active_id(ctx.store) == nil
      refute_received {:fetched, _}
    end
  end

  test "keys of modules this device has never heard of don't create atoms", ctx do
    unheard_of = "MobDeliverUnheardOf#{System.unique_integer([:positive])}xyz.Screen"
    update = body(ctx, [{unheard_of, "bytes"}])

    assert Installer.check(opts(ctx, update, %{sha("bytes") => "bytes"})) == {:ok, :installed}
    assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> unheard_of) end
  end
end
