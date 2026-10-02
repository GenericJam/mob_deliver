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
end
