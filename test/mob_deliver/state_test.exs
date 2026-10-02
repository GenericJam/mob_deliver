defmodule MobDeliver.StateTest do
  # Stops and restarts the :mob_deliver application: not async.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    on_exit(fn -> {:ok, _} = Application.ensure_all_started(:mob_deliver) end)
  end

  defp restart_with_watchdog_state(state) do
    :ok = Application.stop(:mob_deliver)
    root = Application.fetch_env!(:mob_deliver, :root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "watchdog"), :erlang.term_to_binary(state))
    on_exit(fn -> File.rm(Path.join(root, "watchdog")) end)
    {:ok, _} = Application.ensure_all_started(:mob_deliver)
  end

  test "with mob_deliver not running (host tests, early boot) nothing raises" do
    :ok = Application.stop(:mob_deliver)

    assert MobDeliver.update_status() == :ok
    assert MobDeliver.check() == {:error, :not_running}
    assert MobDeliver.resolve(:"Elixir.MobDeliverState.Nowhere") == {:error, :not_running}
    assert MobDeliver.mark_stable() == {:error, :not_running}
    assert MobDeliver.take_rollback_notice() == nil
    assert MobDeliver.rollback_notice() == nil

    assert %{
             running: false,
             active: nil,
             last_check: nil,
             update_status: :ok,
             rollback_notice: nil
           } = MobDeliver.state()
  end

  test "state/0 reports the last check's result and when it ran" do
    before = DateTime.utc_now()
    result = MobDeliver.check()

    assert %{running: true, last_check: %{result: ^result, at: at}} = MobDeliver.state()
    assert DateTime.compare(at, before) != :lt
  end

  test "rollback_notice/0 doesn't consume the notice; take_rollback_notice/0 does" do
    notice = %{rolled_back: String.duplicate("a", 64), at: ~U[2026-10-01 10:00:00Z]}

    restart_with_watchdog_state(%{
      armed: nil,
      boots: 0,
      rejected: [],
      rejections: [],
      notice: notice
    })

    assert MobDeliver.rollback_notice() == notice
    assert MobDeliver.state().rollback_notice == notice
    assert MobDeliver.take_rollback_notice() == notice
    assert MobDeliver.rollback_notice() == nil
  end

  test "check(details: true) says whether the install needs a relaunch; state/0 keeps saying so" do
    {key, private} = MobDeliver.TestPublisher.keypair()
    n = System.unique_integer([:positive])

    # A module this session runs (as bundled code), and a newer version published.
    {module, _} =
      compile("defmodule MobDeliverState#{n}.Home do def v, do: :running end")

    {^module, published} = compile("defmodule MobDeliverState#{n}.Home do def v, do: :new end")
    unload(module)
    {^module, _} = compile("defmodule MobDeliverState#{n}.Home do def v, do: :running end")

    sha = Base.encode16(:crypto.hash(:sha256, published), case: :lower)

    body =
      %{"modules" => %{MobDeliver.Manifest.module_key(module) => "sha256:" <> sha}}
      |> MobDeliver.TestPublisher.fields()
      |> MobDeliver.TestPublisher.sign(private)
      |> JSON.encode!()

    plug = fn
      %{request_path: "/manifest"} = conn -> Plug.Conn.send_resp(conn, 200, body)
      conn -> Plug.Conn.send_resp(conn, 200, published)
    end

    fresh_app()
    on_exit(&fresh_app/0)
    on_exit(fn -> unload(module) end)

    configure(key, plug)
    on_exit(&unconfigure/0)

    refute MobDeliver.state().restart_required
    assert MobDeliver.check(details: true) == {:ok, :installed, %{restart_required: true}}
    assert MobDeliver.state().restart_required
    assert MobDeliver.check(details: true) == {:ok, :current, %{restart_required: true}}
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

  @config [:trusted_publish_key, :endpoint, :app, :channel, :req_options]

  defp configure(key, plug) do
    Application.put_all_env(
      mob_deliver: [
        trusted_publish_key: key,
        endpoint: "https://updates.example.test",
        app: "com.example.app",
        channel: :production,
        req_options: [plug: plug]
      ]
    )
  end

  defp unconfigure, do: Enum.each(@config, &Application.delete_env(:mob_deliver, &1))

  # The application over an empty store.
  defp fresh_app do
    Application.stop(:mob_deliver)
    File.rm_rf!(Application.fetch_env!(:mob_deliver, :root))
    {:ok, _} = Application.ensure_all_started(:mob_deliver)
  end
end
