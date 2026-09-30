defmodule MobDeliver.ResolverTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Manifest, Resolver, SingleFlight, Store, TestPublisher}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    id = System.unique_integer([:positive])
    store = :"resolver_store_#{id}"
    sf = :"resolver_sf_#{id}"
    start_supervised!({Store, name: store, root: root}, id: store)
    start_supervised!({SingleFlight, name: sf}, id: sf)

    %{store: store, sf: sf, key: key, private: private, id: id}
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

  # Activates a manifest mapping each module to the SHA of the given bytes.
  defp activate_manifest(ctx, modules) do
    body =
      %{
        "modules" =>
          Map.new(modules, fn {mod, bin} -> {Manifest.module_key(mod), "sha256:" <> sha(bin)} end)
      }
      |> TestPublisher.fields()
      |> TestPublisher.sign(ctx.private)
      |> JSON.encode!()

    {:ok, manifest} =
      Manifest.verify(body, ctx.key, app: "com.example.app", channel: "production")

    :ok = Store.activate(ctx.store, body, manifest, Store.active_id(ctx.store))
  end

  # Resolver options whose server answers GET /beam/:sha from `blobs`
  # (sha => bytes, or a 0-arity fun run at request time returning bytes).
  defp serving(ctx, blobs) do
    test_pid = self()

    plug = fn conn ->
      "/beam/" <> requested = conn.request_path
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
      client_opts: [endpoint: "https://updates.example.test", req_options: [plug: plug]]
    ]
  end

  defp publish(ctx, modules, blobs) do
    activate_manifest(ctx, modules)
    serving(ctx, blobs)
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

  test "loaded modules resolve immediately; unknown ones are :not_found", ctx do
    opts = publish(ctx, [], %{})

    assert Resolver.resolve(Enum, opts) == :ok

    assert Resolver.resolve(:"Elixir.MobDeliverJit#{ctx.id}.Nowhere", opts) ==
             {:error, :not_found}
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

  test "module keys round-trip for Elixir and Erlang modules" do
    for module <- [MobDeliver.Store, :lists] do
      assert module |> Manifest.module_key() |> Manifest.key_module() == module
    end

    assert Manifest.module_key(MobDeliver.Store) == "MobDeliver.Store"
    assert Manifest.module_key(:lists) == ":lists"
  end
end
