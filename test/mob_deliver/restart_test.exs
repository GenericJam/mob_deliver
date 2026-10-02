defmodule MobDeliver.RestartTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Manifest, Restart, Store, TestPublisher}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    n = System.unique_integer([:positive])
    store = :"restart_store_#{n}"
    start_supervised!({Store, name: store, root: root}, id: store)
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    %{store: store, private: private, verify: verify, n: n}
  end

  defp compile(source) do
    {[{module, binary}], _} =
      Code.with_diagnostics([log: false], fn -> Code.compile_string(source) end)

    {module, binary}
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp install(ctx, modules) do
    body =
      %{
        "modules" =>
          Map.new(modules, fn {mod, bin} -> {Manifest.module_key(mod), "sha256:" <> sha(bin)} end)
      }
      |> TestPublisher.fields()
      |> TestPublisher.sign(ctx.private)
      |> JSON.encode!()

    {:ok, manifest} = ctx.verify.(body)
    for {_mod, bin} <- modules, do: :ok = Store.put_blob(ctx.store, sha(bin), bin)
    :ok = Store.activate(ctx.store, body, manifest, Store.active_id(ctx.store))
  end

  test "nothing installed: no restart pending", ctx do
    refute Restart.required?(ctx.store)
  end

  test "an install with a new version of a module this session runs needs a relaunch to apply",
       ctx do
    # Running now (as bundled code would be): one version.
    {module, _} = compile("defmodule MobDeliverRestart#{ctx.n}.Home do def v, do: :old end")
    on_exit(fn -> unload(module) end)

    # Installed: another.
    {^module, new} = compile("defmodule MobDeliverRestart#{ctx.n}.Home do def v, do: :new end")
    unload(module)
    {^module, _} = compile("defmodule MobDeliverRestart#{ctx.n}.Home do def v, do: :old end")

    install(ctx, [{module, new}])
    assert Restart.required?(ctx.store)
  end

  test "modules not loaded yet take the installed version on first use: no restart pending",
       ctx do
    {module, bin} = compile("defmodule MobDeliverRestart#{ctx.n}.Later do def v, do: :new end")
    unload(module)

    install(ctx, [{module, bin}])
    refute Restart.required?(ctx.store)
  end

  test "a loaded module identical to the installed version needs no restart", ctx do
    {module, bin} = compile("defmodule MobDeliverRestart#{ctx.n}.Same do def v, do: :same end")
    on_exit(fn -> unload(module) end)

    install(ctx, [{module, bin}])
    refute Restart.required?(ctx.store)
  end

  test "modules this session loaded from the installed manifest itself: no restart pending",
       ctx do
    {module, bin} = compile("defmodule MobDeliverRestart#{ctx.n}.Delivered do def v, do: :d end")
    unload(module)
    install(ctx, [{module, bin}])

    path = Store.blob_path(ctx.store, sha(bin))
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), bin)
    on_exit(fn -> unload(module) end)

    refute Restart.required?(ctx.store)
  end
end
