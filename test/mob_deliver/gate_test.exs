defmodule MobDeliver.GateTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Gate, Manifest, Store, TestPublisher}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    n = System.unique_integer([:positive])
    store = :"gate_store_#{n}"
    gate = :"gate_#{n}"
    start_supervised!({Store, name: store, root: root}, id: store)
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    start_supervised!({Gate, name: gate, store: store, verify: verify}, id: gate)
    %{store: store, gate: gate, root: root, private: private, verify: verify}
  end

  defp published(ctx, fields) do
    body = fields |> TestPublisher.fields() |> TestPublisher.sign(ctx.private) |> JSON.encode!()
    {:ok, manifest} = ctx.verify.(body)
    {body, manifest}
  end

  defp record(ctx, fields) do
    {body, manifest} = published(ctx, fields)
    :ok = Gate.record(ctx.gate, body, manifest)
  end

  @early ~U[2026-10-01 00:00:00Z]
  @late ~U[2026-11-01 00:00:00Z]
  @deadline "2026-10-19T00:00:00Z"

  defp status(ctx, app_version, now),
    do: Gate.status(ctx.gate, app_version: app_version, now: now)

  test "below the floor: recommended until the deadline, required from it", ctx do
    record(ctx, %{"min_app_version" => "1.4.0", "force_update_after" => @deadline})

    assert {:recommended, %{min_app_version: "1.4.0"}} = status(ctx, "1.3.9", @early)

    assert {:required, %{force_update_after: ~U[2026-10-19 00:00:00Z]}} =
             status(ctx, "1.3.9", @late)

    assert {:required, _} = status(ctx, "1.3.9", ~U[2026-10-19 00:00:00Z])
  end

  test "at or above the floor, or with no floor, the gate is open", ctx do
    record(ctx, %{"min_app_version" => "1.4", "force_update_after" => @deadline})

    for version <- ["1.4", "1.4.0", "1.4.1", "2.0", "1.10"] do
      assert status(ctx, version, @late) == :ok
    end

    assert status(ctx, "1.3.99", @late) != :ok
  end

  test "a floor without a deadline only ever recommends", ctx do
    record(ctx, %{"min_app_version" => "2.0", "force_update_after" => nil})
    assert {:recommended, _} = status(ctx, "1.0", @late)
  end

  test "an unknown or unparseable app version leaves the gate open", ctx do
    record(ctx, %{"min_app_version" => "1.4.0", "force_update_after" => @deadline})

    for version <- [nil, "", "1.4-beta", "v1.3"] do
      assert status(ctx, version, @late) == :ok
    end
  end

  test "an older signed manifest can't replace a newer one to lift the gate", ctx do
    record(ctx, %{
      "issued_at" => "2026-09-20T00:00:00Z",
      "min_app_version" => "1.4.0",
      "force_update_after" => @deadline
    })

    record(ctx, %{"issued_at" => "2026-09-10T00:00:00Z", "min_app_version" => nil})

    assert {:required, _} = status(ctx, "1.0", @late)
  end

  test "a restarted gate reloads the persisted one, re-verified", ctx do
    record(ctx, %{"min_app_version" => "1.4.0", "force_update_after" => @deadline})

    restarted = :"#{ctx.gate}_restarted"

    start_supervised!({Gate, name: restarted, store: ctx.store, verify: ctx.verify},
      id: restarted
    )

    assert {:required, _} = Gate.status(restarted, app_version: "1.0", now: @late)
  end

  test "a tampered gate file is ignored on start", ctx do
    record(ctx, %{"min_app_version" => "1.4.0", "force_update_after" => @deadline})
    path = Path.join(ctx.root, "gate.json")
    File.write!(path, String.replace(File.read!(path), "1.4.0", "9.9.9"))

    restarted = :"#{ctx.gate}_tampered"

    start_supervised!({Gate, name: restarted, store: ctx.store, verify: ctx.verify},
      id: restarted
    )

    assert Gate.status(restarted, app_version: "1.0", now: @late) == :ok
  end

  test "a verified floor applies at once even if it can't be persisted", ctx do
    File.mkdir_p!(ctx.root)
    File.chmod!(ctx.root, 0o500)
    on_exit(fn -> File.chmod(ctx.root, 0o700) end)

    {body, manifest} =
      published(ctx, %{"min_app_version" => "1.4.0", "force_update_after" => @deadline})

    assert {:error, _} = Gate.record(ctx.gate, body, manifest)
    assert {:required, _} = status(ctx, "1.0", @late)
  end

  test "a recorded manifest that changes this app's verdict is reported at once; one that doesn't isn't",
       ctx do
    test_pid = self()
    watched = :"#{ctx.gate}_watched"

    start_supervised!(
      {Gate,
       name: watched,
       store: ctx.store,
       verify: ctx.verify,
       app_version: "1.0",
       on_change: fn status -> send(test_pid, {:changed, status}) end},
      id: watched
    )

    past = "2026-01-01T00:00:00Z"

    record_in = fn issued_at, fields ->
      {body, manifest} = published(ctx, Map.put(fields, "issued_at", issued_at))
      :ok = Gate.record(watched, body, manifest)
    end

    record_in.("2026-09-20T00:00:00Z", %{"min_app_version" => "2.0", "force_update_after" => past})

    assert_receive {:changed, {:required, _}}

    record_in.("2026-09-21T00:00:00Z", %{"min_app_version" => "3.0", "force_update_after" => past})

    refute_receive {:changed, _}, 50

    record_in.("2026-09-22T00:00:00Z", %{"min_app_version" => nil})
    assert_receive {:changed, :ok}
  end

  test "installable?/2 follows the floor" do
    manifest = %Manifest{
      app: "a",
      channel: "c",
      issued_at: @early,
      modules: %{},
      min_app_version: "1.4"
    }

    assert Gate.installable?(manifest, "1.4.0")
    refute Gate.installable?(manifest, "1.3")
    assert Gate.installable?(%{manifest | min_app_version: nil}, "0.1")
    assert Gate.installable?(manifest, nil)
  end
end
