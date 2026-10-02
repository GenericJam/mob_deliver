defmodule MobDeliver.BuildChangeTest do
  # Puts a directory on the VM's code path and loads/unloads modules: not async.
  use ExUnit.Case, async: false

  alias MobDeliver.{Boot, Gate, Installer, Manifest, SingleFlight, Store, TestPublisher, Watchdog}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp} do
    {key, private} = TestPublisher.keypair()
    n = System.unique_integer([:positive])
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    module = :"Elixir.MobDeliverBuild#{n}.YouScreen"

    # The app binary's own BEAMs: a directory on the code path.
    bundled = Path.join(tmp, "bundled")
    File.mkdir_p!(bundled)
    true = :code.add_patha(String.to_charlist(bundled))

    on_exit(fn ->
      :code.del_path(String.to_charlist(bundled))
      unload(module)
    end)

    %{
      root: Path.join(tmp, "store"),
      bundled: bundled,
      key: key,
      private: private,
      verify: verify,
      module: module,
      n: n
    }
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp compile(ctx, marker) do
    {[{_, binary}], _} =
      Code.with_diagnostics([log: false], fn ->
        Code.compile_string(
          "defmodule #{inspect(ctx.module)} do def v, do: #{inspect(marker)} end"
        )
      end)

    unload(ctx.module)
    binary
  end

  # A native build (or a BEAM push) with `marker` as the bundled version.
  defp build(ctx, marker) do
    File.write!(Path.join(ctx.bundled, "#{ctx.module}.beam"), compile(ctx, marker))
  end

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp publish(ctx, delivered, extra \\ %{}) do
    %{"modules" => %{Manifest.module_key(ctx.module) => "sha256:" <> sha(delivered)}}
    |> Map.merge(extra)
    |> TestPublisher.fields()
    |> TestPublisher.sign(ctx.private)
    |> JSON.encode!()
  end

  # One app launch in a fresh VM's worth of processes over the same store.
  defp launch(ctx) do
    unload(ctx.module)
    n = System.unique_integer([:positive])

    app = %{
      store: :"bc_store_#{n}",
      watchdog: :"bc_wd_#{n}",
      gate: :"bc_gate_#{n}",
      sf: :"bc_sf_#{n}"
    }

    start_supervised!({Store, name: app.store, root: ctx.root}, id: app.store)

    start_supervised!({Watchdog, name: app.watchdog, store: app.store, app_version: "2.0.0"},
      id: app.watchdog
    )

    start_supervised!(
      {Gate, name: app.gate, store: app.store, verify: ctx.verify, on_change: fn _ -> :ok end},
      id: app.gate
    )

    start_supervised!({SingleFlight, name: app.sf}, id: app.sf)

    :ok =
      Boot.run(store: app.store, watchdog: app.watchdog, verify: ctx.verify, poller: nil)

    app
  end

  defp check(ctx, app, body, blobs) do
    plug = fn
      %{request_path: "/manifest"} = conn ->
        Plug.Conn.send_resp(conn, 200, body)

      %{request_path: "/beam/" <> requested} = conn ->
        case Map.fetch(blobs, requested) do
          {:ok, bytes} -> Plug.Conn.send_resp(conn, 200, bytes)
          :error -> Plug.Conn.send_resp(conn, 404, "")
        end
    end

    Installer.check(
      store: app.store,
      watchdog: app.watchdog,
      gate: app.gate,
      single_flight: app.sf,
      app_version: "2.0.0",
      client_opts: [
        endpoint: "https://updates.example.test",
        app: "com.example.app",
        channel: "production",
        trusted_publish_key: ctx.key,
        req_options: [plug: plug]
      ]
    )
  end

  defp running(ctx), do: ctx.module.v()

  test "a rollback onto a previous manifest that the build has outgrown runs bundled code",
       ctx do
    build(ctx, :bundled_v1)
    first = launch(ctx)
    a_bytes = compile(ctx, :delivered_a)

    assert check(ctx, first, publish(ctx, a_bytes), %{sha(a_bytes) => a_bytes}) ==
             {:ok, :installed}

    on_a = launch(ctx)
    :ok = Watchdog.mark_stable(on_a.watchdog)

    # A BEAM push, then B is installed in the same session (on the pushed base).
    build(ctx, :pushed)
    b_bytes = compile(ctx, :delivered_b)
    b = publish(ctx, b_bytes, %{"issued_at" => "2026-10-02T00:00:00Z"})
    assert check(ctx, on_a, b, %{sha(b_bytes) => b_bytes}) == {:ok, :installed}

    # B's probation launch dies; the next one rolls back to A, which the
    # pushed code has outgrown.
    launch(ctx)
    rolled = launch(ctx)

    assert running(ctx) == :pushed
    assert Store.active(rolled.store) == nil
    assert %{rolled_back: _} = Watchdog.take_notice(rolled.watchdog)
  end

  test "a new build's bundled code wins over an older delivered manifest, which isn't reinstalled; a later publish is",
       ctx do
    build(ctx, :bundled_v1)
    first = launch(ctx)

    a_bytes = compile(ctx, :delivered_a)
    a = publish(ctx, a_bytes)
    assert check(ctx, first, a, %{sha(a_bytes) => a_bytes}) == {:ok, :installed}

    on_a = launch(ctx)
    assert running(ctx) == :delivered_a
    :ok = Watchdog.mark_stable(on_a.watchdog)

    # Cable deploy of a new native build, nothing published.
    build(ctx, :bundled_v2)
    new_build = launch(ctx)

    assert running(ctx) == :bundled_v2
    assert Store.active(new_build.store) == nil
    # Not a crash: nothing to tell the user, nothing rejected.
    assert Watchdog.take_notice(new_build.watchdog) == nil
    {:ok, a_manifest} = ctx.verify.(a)
    refute Watchdog.rejected?(new_build.watchdog, Store.manifest_id(a), a_manifest)

    # The server still has A (also re-published as is): not installed again.
    assert check(ctx, new_build, a, %{sha(a_bytes) => a_bytes}) == {:ok, :stale_for_build}

    a_again = publish(ctx, a_bytes, %{"issued_at" => "2026-10-01T00:00:00Z"})
    assert check(ctx, new_build, a_again, %{sha(a_bytes) => a_bytes}) == {:ok, :stale_for_build}
    assert Store.active(new_build.store) == nil

    # A publish made from the new build's source installs as usual.
    b_bytes = compile(ctx, :delivered_b)
    b = publish(ctx, b_bytes, %{"issued_at" => "2026-10-02T00:00:00Z"})
    assert check(ctx, new_build, b, %{sha(b_bytes) => b_bytes}) == {:ok, :installed}

    launch(ctx)
    assert running(ctx) == :delivered_b
  end

  test "a BEAM push of a newer bundled version takes effect at the next launch", ctx do
    build(ctx, :bundled_v1)
    first = launch(ctx)
    a_bytes = compile(ctx, :delivered_a)

    assert check(ctx, first, publish(ctx, a_bytes), %{sha(a_bytes) => a_bytes}) ==
             {:ok, :installed}

    on_a = launch(ctx)
    :ok = Watchdog.mark_stable(on_a.watchdog)

    # mix mob.deploy (no --native) replaces the .beam in the app's directory.
    build(ctx, :pushed)
    launch(ctx)
    assert running(ctx) == :pushed
  end

  test "a manifest installed before builds were tracked is retired if it overrides different bundled code",
       ctx do
    build(ctx, :bundled_v2)
    a_bytes = compile(ctx, :delivered_a)
    install_untracked(ctx, a_bytes)

    app = launch(ctx)
    assert running(ctx) == :bundled_v2
    assert Store.active(app.store) == nil
    assert Watchdog.take_notice(app.watchdog) == nil
  end

  test "a manifest installed before builds were tracked keeps running if its versions are the bundled ones",
       ctx do
    build(ctx, :same)
    same_bytes = File.read!(Path.join(ctx.bundled, "#{ctx.module}.beam"))
    id = install_untracked(ctx, same_bytes)

    app = launch(ctx)
    assert Store.active_id(app.store) == id
    {:ok, {_, md5}} = :beam_lib.md5(same_bytes)
    key = Manifest.module_key(ctx.module)
    assert Store.base(app.store, id) == %{key => Base.encode16(md5, case: :lower)}
  end

  # As mob_deliver 0.2.1 left it: active slot, blob, no base.
  defp install_untracked(ctx, delivered) do
    n = System.unique_integer([:positive])
    store = :"bc_old_store_#{n}"
    start_supervised!({Store, name: store, root: ctx.root}, id: store)
    {:ok, _} = Store.boot(store, ctx.verify)
    body = publish(ctx, delivered)
    {:ok, manifest} = ctx.verify.(body)
    :ok = Store.put_blob(store, sha(delivered), delivered)
    :ok = Store.activate(store, body, manifest, nil)
    Store.manifest_id(body)
  end
end
