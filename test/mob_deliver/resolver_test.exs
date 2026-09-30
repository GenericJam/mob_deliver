defmodule MobDeliver.ResolverTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{
    Gate,
    Manifest,
    Refresh,
    Resolver,
    SingleFlight,
    Store,
    TestPublisher,
    Watchdog
  }

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    id = System.unique_integer([:positive])
    store = :"resolver_store_#{id}"
    sf = :"resolver_sf_#{id}"
    gate = :"resolver_gate_#{id}"
    watchdog = :"resolver_wd_#{id}"
    refresh = :"resolver_refresh_#{id}"
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    start_supervised!({Store, name: store, root: root}, id: store)
    start_supervised!({SingleFlight, name: sf}, id: sf)
    start_supervised!({Gate, name: gate, store: store, verify: verify}, id: gate)

    start_supervised!({Watchdog, name: watchdog, store: store, app_version: "2.0.0"},
      id: watchdog
    )

    # Most tests run after the root screen's first frame (the router hook's
    # mark_stable); the refresh tests before it start their own watchdog.
    :ok = Watchdog.mark_stable(watchdog)

    start_supervised!({Refresh, name: refresh}, id: refresh)
    # What the server's POST /manifest answers (nil: 404).
    latest = start_supervised!({Agent, fn -> nil end})

    %{
      store: store,
      sf: sf,
      gate: gate,
      watchdog: watchdog,
      refresh: refresh,
      latest: latest,
      root: root,
      key: key,
      private: private,
      id: id
    }
  end

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  # Compiles to a real .beam, then unloads it so it's only reachable through
  # the store — like an expansion screen that isn't bundled.
  defp beam(source) do
    # The callee of a caller-under-test is deliberately unloaded; don't warn.
    {[{module, binary}], _diagnostics} =
      Code.with_diagnostics([log: false], fn -> Code.compile_string(source) end)

    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    {module, binary}
  end

  defp signed(ctx, modules, extra \\ %{}) do
    %{
      "modules" =>
        Map.new(modules, fn {mod, bin} -> {Manifest.module_key(mod), "sha256:" <> sha(bin)} end)
    }
    |> Map.merge(extra)
    |> TestPublisher.fields()
    |> TestPublisher.sign(ctx.private)
    |> JSON.encode!()
  end

  # The server publishes a manifest mapping each module to the SHA of the
  # given bytes; the device doesn't install it.
  defp publish_latest(ctx, modules, extra \\ %{}) do
    body = signed(ctx, modules, extra)
    Agent.update(ctx.latest, fn _ -> body end)
    body
  end

  # Publishes a manifest and installs it on the device.
  defp activate_manifest(ctx, modules) do
    body = publish_latest(ctx, modules)

    {:ok, manifest} =
      Manifest.verify(body, ctx.key, app: "com.example.app", channel: "production")

    :ok = Store.activate(ctx.store, body, manifest, Store.active_id(ctx.store))
  end

  # Resolver options whose server answers POST /manifest with the latest
  # published manifest and GET /beam/:sha from `blobs` (sha => bytes, or a
  # 0-arity fun run at request time returning bytes).
  defp serving(ctx, blobs) do
    test_pid = self()
    latest = ctx.latest

    plug = fn
      %{request_path: "/manifest"} = conn ->
        send(test_pid, :manifest_fetched)

        case Agent.get(latest, & &1) do
          nil -> Plug.Conn.send_resp(conn, 404, "")
          body -> Plug.Conn.send_resp(conn, 200, body)
        end

      %{request_path: "/beam/" <> requested} = conn ->
        send(test_pid, {:fetched, requested})

        case Map.fetch(blobs, requested) do
          {:ok, bytes_fun} when is_function(bytes_fun, 0) ->
            Plug.Conn.send_resp(conn, 200, bytes_fun.())

          {:ok, bytes} ->
            Plug.Conn.send_resp(conn, 200, bytes)

          :error ->
            Plug.Conn.send_resp(conn, 404, "")
        end
    end

    [
      store: ctx.store,
      single_flight: ctx.sf,
      gate: ctx.gate,
      watchdog: ctx.watchdog,
      refresh: ctx.refresh,
      refresh_interval: 60_000,
      app_version: "2.0.0",
      client_opts: [
        endpoint: "https://updates.example.test",
        app: "com.example.app",
        channel: "production",
        trusted_publish_key: ctx.key,
        req_options: [plug: plug]
      ]
    ]
  end

  defp publish(ctx, modules, blobs) do
    activate_manifest(ctx, modules)
    serving(ctx, blobs)
  end

  defp manifest_fetches do
    receive do
      :manifest_fetched -> 1 + manifest_fetches()
    after
      0 -> 0
    end
  end

  defp fetch_count(sha) do
    receive do
      {:fetched, ^sha} -> 1 + fetch_count(sha)
    after
      0 -> 0
    end
  end

  test "a cache miss fetches, verifies, and loads the module", ctx do
    {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.Home do def hi, do: :delivered end")
    opts = publish(ctx, [{mod, bin}], %{sha(bin) => bin})

    assert Resolver.resolve(mod, opts) == :ok
    assert mod.hi() == :delivered
    assert Store.read_blob(ctx.store, sha(bin)) == {:ok, bin}
  end

  test "concurrent resolves of one module fetch it once", ctx do
    {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.Busy do def hi, do: :once end")
    opts = publish(ctx, [{mod, bin}], %{sha(bin) => bin})

    results =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> Resolver.resolve(mod, opts) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.uniq(results) == [:ok]
    assert fetch_count(sha(bin)) == 1
  end

  test "delivered modules the target calls are fetched and loaded with it", ctx do
    {callee, callee_bin} =
      beam("defmodule MobDeliverJit#{ctx.id}.Helper do def word, do: :helped end")

    {caller, caller_bin} =
      beam(
        "defmodule MobDeliverJit#{ctx.id}.Screen do def run, do: #{inspect(callee)}.word() end"
      )

    opts =
      publish(ctx, [{caller, caller_bin}, {callee, callee_bin}], %{
        sha(caller_bin) => caller_bin,
        sha(callee_bin) => callee_bin
      })

    assert Resolver.resolve(caller, opts) == :ok
    assert :code.is_loaded(callee) != false
    assert caller.run() == :helped
  end

  test "bytes that don't match the manifest SHA are rejected and nothing loads", ctx do
    {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.Forged do def hi, do: :real end")
    opts = publish(ctx, [{mod, bin}], %{sha(bin) => bin <> "tampered"})

    assert Resolver.resolve(mod, opts) == {:error, :sha_mismatch}
    refute :code.is_loaded(mod)
  end

  test "a blob that defines a different module than the manifest names is not loaded", ctx do
    {named, _} = beam("defmodule MobDeliverJit#{ctx.id}.Named do def hi, do: :named end")
    {other, other_bin} = beam("defmodule MobDeliverJit#{ctx.id}.Other do def hi, do: :other end")
    opts = publish(ctx, [{named, other_bin}], %{sha(other_bin) => other_bin})

    assert Resolver.resolve(named, opts) == {:error, {:module_mismatch, other}}
    refute :code.is_loaded(named)
    refute :code.is_loaded(other)
  end

  test "a blob already in the store loads without a fetch", ctx do
    {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.Cached do def hi, do: :local end")
    opts = publish(ctx, [{mod, bin}], %{})
    :ok = Store.put_blob(ctx.store, sha(bin), bin)

    assert Resolver.resolve(mod, opts) == :ok
    assert fetch_count(sha(bin)) == 0
  end

  test "loaded modules resolve immediately", ctx do
    assert Resolver.resolve(Enum, serving(ctx, %{})) == :ok
    assert manifest_fetches() == 0
  end

  test "a callee that fails to load leaves the target unloaded, and a later resolve retries",
       ctx do
    {callee, callee_bin} = beam("defmodule MobDeliverJit#{ctx.id}.Dep do def v, do: :dep end")
    {_wrong, wrong_bin} = beam("defmodule MobDeliverJit#{ctx.id}.Wrong do def v, do: :wrong end")

    {caller, caller_bin} =
      beam("defmodule MobDeliverJit#{ctx.id}.Top do def run, do: #{inspect(callee)}.v() end")

    broken =
      publish(ctx, [{caller, caller_bin}, {callee, wrong_bin}], %{
        sha(caller_bin) => caller_bin,
        sha(wrong_bin) => wrong_bin
      })

    assert {:error, {:module_mismatch, _}} = Resolver.resolve(caller, broken)
    refute :code.is_loaded(caller)

    fixed =
      publish(ctx, [{caller, caller_bin}, {callee, callee_bin}], %{
        sha(caller_bin) => caller_bin,
        sha(callee_bin) => callee_bin
      })

    assert Resolver.resolve(caller, fixed) == :ok
    assert caller.run() == :dep
  end

  test "the whole closure comes from one manifest even if another activates mid-resolve", ctx do
    helper_name = "MobDeliverJit#{ctx.id}.Helper"
    {helper, old_helper} = beam("defmodule #{helper_name} do def word, do: :old_release end")
    {^helper, new_helper} = beam("defmodule #{helper_name} do def word, do: :new_release end")

    {screen, screen_bin} =
      beam("defmodule MobDeliverJit#{ctx.id}.Pinned do def run, do: #{helper_name}.word() end")

    activate_manifest(ctx, [{screen, screen_bin}, {helper, old_helper}])

    # Serving the screen's blob activates the next release before the
    # resolver gets to the helper.
    opts =
      serving(ctx, %{
        sha(screen_bin) => fn ->
          activate_manifest(ctx, [{screen, screen_bin}, {helper, new_helper}])
          screen_bin
        end,
        sha(old_helper) => old_helper,
        sha(new_helper) => new_helper
      })

    assert Resolver.resolve(screen, opts) == :ok
    assert screen.run() == :old_release
    assert fetch_count(sha(new_helper)) == 0
  end

  describe "a module the active manifest doesn't deliver" do
    test "published after the last install: loaded from the server's newest manifest, which isn't installed",
         ctx do
      {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.Late do def hi, do: :late end")
      opts = publish(ctx, [], %{sha(bin) => bin})
      installed = Store.active_id(ctx.store)
      publish_latest(ctx, [{mod, bin}])

      assert Resolver.resolve(mod, opts) == :ok
      assert mod.hi() == :late
      assert Store.active_id(ctx.store) == installed
    end

    test "with nothing installed yet, a delivered-only module comes from the server's manifest",
         ctx do
      {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.FirstLaunch do def hi, do: :jit end")
      publish_latest(ctx, [{mod, bin}])

      assert Resolver.resolve(mod, serving(ctx, %{sha(bin) => bin})) == :ok
      assert mod.hi() == :jit
      assert Store.active(ctx.store) == nil
    end

    test "unknown to the server too: :not_found", ctx do
      opts = publish(ctx, [], %{})

      assert Resolver.resolve(:"Elixir.MobDeliverJit#{ctx.id}.Nowhere", opts) ==
               {:error, :not_found}
    end

    test "the server can't be asked: its error", ctx do
      opts = serving(ctx, %{})

      assert Resolver.resolve(:"Elixir.MobDeliverJit#{ctx.id}.Offline", opts) ==
               {:error, {:http_status, 404}}
    end

    test "a burst of misses asks the server once per refresh interval", ctx do
      opts = Keyword.put(publish(ctx, [], %{}), :refresh_interval, 1_000)
      unknown = for n <- 1..10, do: :"Elixir.MobDeliverJit#{ctx.id}.Unknown#{n}"

      unknown
      |> Task.async_stream(&Resolver.resolve(&1, opts), max_concurrency: 10)
      |> Enum.each(&assert(&1 == {:ok, {:error, :not_found}}))

      Enum.each(unknown, &assert(Resolver.resolve(&1, opts) == {:error, :not_found}))
      assert manifest_fetches() == 1

      Process.sleep(1_100)
      assert Resolver.resolve(hd(unknown), opts) == {:error, :not_found}
      assert manifest_fetches() == 1
    end

    test "before the root screen's first frame nothing is fetched for it: :not_found", ctx do
      {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.Early do def hi, do: :early end")
      publish_latest(ctx, [{mod, bin}])
      booting = :"#{ctx.watchdog}_booting"

      start_supervised!({Watchdog, name: booting, store: ctx.store, app_version: "2.0.0"},
        id: booting
      )

      opts = Keyword.put(serving(ctx, %{sha(bin) => bin}), :watchdog, booting)

      assert Resolver.resolve(mod, opts) == {:error, :not_found}
      refute :code.is_loaded(mod)
      assert manifest_fetches() == 0

      :ok = Watchdog.mark_stable(booting)
      assert Resolver.resolve(mod, opts) == :ok
    end

    test "a refreshed manifest that puts this app past its forced-update deadline gates at once",
         ctx do
      opts = publish(ctx, [], %{})

      publish_latest(ctx, [], %{
        "min_app_version" => "3.0",
        "force_update_after" => "2026-01-01T00:00:00Z"
      })

      assert Resolver.resolve(:"Elixir.MobDeliverJit#{ctx.id}.Anything", opts) ==
               {:error, :update_required}
    end

    test "the server's manifest isn't used if this app version is below its floor", ctx do
      {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.TooNew do def hi, do: :new end")
      opts = publish(ctx, [], %{sha(bin) => bin})
      publish_latest(ctx, [{mod, bin}], %{"min_app_version" => "3.0"})

      assert Resolver.resolve(mod, opts) == {:error, :not_found}
      refute :code.is_loaded(mod)
    end

    test "the server's manifest isn't used if this device rolled its modules back", ctx do
      {mod, bin} = beam("defmodule MobDeliverJit#{ctx.id}.Bad do def hi, do: :bad end")
      rolled_back = signed(ctx, [{mod, bin}])

      {:ok, manifest} =
        Manifest.verify(rolled_back, ctx.key, app: "com.example.app", channel: "production")

      File.write!(
        Path.join(ctx.root, "watchdog"),
        :erlang.term_to_binary(%{
          armed: nil,
          boots: 0,
          rejected: [],
          rejected_code: [{Manifest.code_id(manifest), "2.0.0"}],
          notice: nil
        })
      )

      # A launch after the rollback: a fresh watchdog reads the state file.
      launched = :"#{ctx.watchdog}_launched"

      start_supervised!({Watchdog, name: launched, store: ctx.store, app_version: "2.0.0"},
        id: launched
      )

      :ok = Watchdog.mark_stable(launched)
      opts = Keyword.put(serving(ctx, %{sha(bin) => bin}), :watchdog, launched)
      # Same modules, published again later.
      publish_latest(ctx, [{mod, bin}], %{"issued_at" => "2026-09-30T00:00:00Z"})

      assert Resolver.resolve(mod, opts) == {:error, :not_found}
      refute :code.is_loaded(mod)
    end

    test "bundled code resolves without asking the server", ctx do
      opts = serving(ctx, %{})

      # stdlib's :erl_tar is on the code path but not loaded in the test VM.
      assert Resolver.resolve(:erl_tar, opts) == :ok
      assert :code.is_loaded(:erl_tar) != false
      assert manifest_fetches() == 0
    end
  end

  test "past the forced-update deadline nothing resolves, loaded or not", ctx do
    body =
      %{"min_app_version" => "2.0", "force_update_after" => "2026-10-19T00:00:00Z"}
      |> TestPublisher.fields()
      |> TestPublisher.sign(ctx.private)
      |> JSON.encode!()

    {:ok, manifest} =
      Manifest.verify(body, ctx.key, app: "com.example.app", channel: "production")

    :ok = Gate.record(ctx.gate, body, manifest)

    opts = Keyword.put(serving(ctx, %{}), :app_version, "1.0")

    assert Resolver.resolve(Enum, [now: ~U[2026-11-01 00:00:00Z]] ++ opts) ==
             {:error, :update_required}

    assert Resolver.resolve(Enum, [now: ~U[2026-10-01 00:00:00Z]] ++ opts) == :ok
  end

  test "module keys round-trip for Elixir and Erlang modules" do
    for module <- [MobDeliver.Store, :lists] do
      assert module |> Manifest.module_key() |> Manifest.key_module() == module
    end

    assert Manifest.module_key(MobDeliver.Store) == "MobDeliver.Store"
    assert Manifest.module_key(:lists) == ":lists"
  end
end
