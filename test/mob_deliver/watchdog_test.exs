defmodule MobDeliver.WatchdogTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Boot, Manifest, Store, TestPublisher, Watchdog}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    %{root: root, private: private, verify: verify}
  end

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp body(ctx, modules) when is_list(modules) do
    %{"modules" => Map.new(modules, fn {key, bin} -> {key, "sha256:" <> sha(bin)} end)}
    |> TestPublisher.fields()
    |> TestPublisher.sign(ctx.private)
    |> JSON.encode!()
  end

  defp body(ctx, label), do: body(ctx, [{"MyApp.Home", label}])

  # Fresh processes over the same on-disk store — one app launch's worth.
  defp processes(ctx) do
    n = System.unique_integer([:positive])
    store = :"wd_store_#{n}"
    watchdog = :"wd_#{n}"
    start_supervised!({Store, name: store, root: ctx.root}, id: store)
    start_supervised!({Watchdog, name: watchdog, store: store}, id: watchdog)
    %{store: store, watchdog: watchdog}
  end

  # One app launch: the plugin's boot checks, returning the watchdog outcome.
  defp launch(ctx) do
    app = processes(ctx)
    {:ok, _} = Store.boot(app.store, ctx.verify)
    Map.put(app, :outcome, Watchdog.on_boot(app.watchdog, ctx.verify))
  end

  defp try_install(ctx, app, label) do
    b = body(ctx, label)
    {:ok, manifest} = ctx.verify.(b)
    Watchdog.install(app.watchdog, b, manifest, Store.active_id(app.store))
  end

  defp install(ctx, app, label) do
    {:ok, :installed} = try_install(ctx, app, label)
    Store.manifest_id(body(ctx, label))
  end

  defp stable_install(ctx, label) do
    id = install(ctx, launch(ctx), label)
    Watchdog.mark_stable(launch(ctx).watchdog)
    id
  end

  describe "probation" do
    test "an update whose first boot dies before first idle is rolled back on the next boot",
         ctx do
      good = stable_install(ctx, "good")
      bad = install(ctx, launch(ctx), "bad")

      first = launch(ctx)
      assert first.outcome == {:ok, :armed}
      assert Store.active_id(first.store) == bad
      # ...the app dies here, before first idle.

      second = launch(ctx)
      assert second.outcome == {:ok, :rolled_back}
      assert Store.active_id(second.store) == good
      assert %{rolled_back: ^bad} = Watchdog.take_notice(second.watchdog)
      assert Watchdog.take_notice(second.watchdog) == nil
      assert Watchdog.rejected?(second.watchdog, bad)
      assert try_install(ctx, second, "bad") == {:ok, :rejected}
    end

    test "an update that reaches first idle stays through later crashes", ctx do
      stable_install(ctx, "good")
      update = install(ctx, launch(ctx), "update")
      Watchdog.mark_stable(launch(ctx).watchdog)

      for _ <- 1..3 do
        crashed = launch(ctx)
        assert crashed.outcome == {:ok, :clean}
        assert Store.active_id(crashed.store) == update
      end
    end

    test "consecutive crashes after a rollback don't swap slots again", ctx do
      good = stable_install(ctx, "good")
      install(ctx, launch(ctx), "bad")
      launch(ctx)
      assert launch(ctx).outcome == {:ok, :rolled_back}

      for _ <- 1..3 do
        app = launch(ctx)
        assert app.outcome == {:ok, :clean}
        assert Store.active_id(app.store) == good
      end
    end

    test "a failed first-ever install rolls back to bundled code", ctx do
      install(ctx, launch(ctx), "first")
      launch(ctx)

      app = launch(ctx)
      assert app.outcome == {:ok, :rolled_back}
      assert Store.active_id(app.store) == nil
    end

    test "reaching idle in the session that installed an update doesn't vouch for it", ctx do
      good = stable_install(ctx, "good")
      app = launch(ctx)
      install(ctx, app, "fresh")
      Watchdog.mark_stable(app.watchdog)

      assert launch(ctx).outcome == {:ok, :armed}
      rolled = launch(ctx)
      assert rolled.outcome == {:ok, :rolled_back}
      assert Store.active_id(rolled.store) == good
    end
  end

  describe "install transaction" do
    test "no install while the booted update is on probation", ctx do
      stable_install(ctx, "good")
      install(ctx, launch(ctx), "probation")
      app = launch(ctx)

      assert try_install(ctx, app, "next") == {:ok, :deferred}
      Watchdog.mark_stable(app.watchdog)
      assert try_install(ctx, app, "next") == {:ok, :installed}
    end

    test "a second install waits until the first has proven itself", ctx do
      good = stable_install(ctx, "good")
      app = launch(ctx)
      first = install(ctx, app, "first")

      assert try_install(ctx, app, "second") == {:ok, :deferred}
      assert Store.active_id(app.store) == first

      # If `first` then fails, the rollback lands on the proven `good`.
      launch(ctx)
      rolled = launch(ctx)
      assert Store.active_id(rolled.store) == good
    end

    test "a rolled-back manifest stays rejected however it's re-encoded", ctx do
      stable_install(ctx, "good")
      install(ctx, launch(ctx), "bad")
      launch(ctx)
      app = launch(ctx)
      assert app.outcome == {:ok, :rolled_back}

      reencoded = "  \n" <> body(ctx, "bad") <> "\n"
      {:ok, manifest} = ctx.verify.(reencoded)

      assert Watchdog.install(app.watchdog, reencoded, manifest, Store.active_id(app.store)) ==
               {:ok, :rejected}
    end

    test "installing the active manifest again doesn't put it back on probation", ctx do
      good = stable_install(ctx, "good")
      assert try_install(ctx, launch(ctx), "good") == {:ok, :current}

      for _ <- 1..2 do
        assert Store.active_id(launch(ctx).store) == good
      end
    end

    test "of concurrent installs exactly one wins, and it's the one on probation", ctx do
      stable_install(ctx, "good")
      app = launch(ctx)

      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn -> {i, try_install(ctx, app, "candidate #{i}")} end)
        end)
        |> Enum.map(&Task.await/1)

      assert [{winner, {:ok, :installed}}] =
               Enum.filter(results, &match?({_, {:ok, :installed}}, &1))

      assert Store.active_id(app.store) == Store.manifest_id(body(ctx, "candidate #{winner}"))

      assert launch(ctx).outcome == {:ok, :armed}
      assert launch(ctx).outcome == {:ok, :rolled_back}
    end
  end

  describe "crash and disk-failure recovery" do
    test "a crash between arming and activating leaves the old manifest in place", ctx do
      good = stable_install(ctx, "good")

      File.write!(
        Path.join(ctx.root, "watchdog"),
        :erlang.term_to_binary(%{
          armed: Store.manifest_id(body(ctx, "never activated")),
          boots: 0,
          rejected: [],
          notice: nil
        })
      )

      for _ <- 1..2 do
        next = launch(ctx)
        assert next.outcome == {:ok, :clean}
        assert Store.active_id(next.store) == good
      end
    end

    test "a crash between recording a rejection and rolling back finishes the rollback", ctx do
      good = stable_install(ctx, "good")
      bad = install(ctx, launch(ctx), "bad")

      File.write!(
        Path.join(ctx.root, "watchdog"),
        :erlang.term_to_binary(%{armed: nil, boots: 0, rejected: [bad], notice: nil})
      )

      app = launch(ctx)
      assert app.outcome == {:ok, :rolled_back}
      assert Store.active_id(app.store) == good
    end

    test "if the probation record can't be written, the boot runs bundled code", ctx do
      stable_install(ctx, "good")
      update = install(ctx, launch(ctx), "update")

      File.chmod!(ctx.root, 0o500)
      on_exit(fn -> File.chmod(ctx.root, 0o700) end)

      app = processes(ctx)

      assert Boot.run(
               store: app.store,
               watchdog: app.watchdog,
               gate: nil,
               verify: ctx.verify,
               poller: nil
             ) ==
               :ok

      assert Store.active(app.store) == nil

      # Nothing durable changed: the update still gets its probation boot.
      File.chmod!(ctx.root, 0o700)
      next = launch(ctx)
      assert next.outcome == {:ok, :armed}
      assert Store.active_id(next.store) == update
    end

    test "a corrupt watchdog file puts the active manifest back on probation", ctx do
      good = stable_install(ctx, "good")
      File.write!(Path.join(ctx.root, "watchdog"), "garbage")

      assert launch(ctx).outcome == {:ok, :armed}
      # ...and it's rolled back if that boot dies, as for any unproven manifest.
      rolled = launch(ctx)
      assert rolled.outcome == {:ok, :rolled_back}
      refute Store.active_id(rolled.store) == good
    end

    test "a corrupt watchdog file with nothing active starts clean", ctx do
      File.mkdir_p!(ctx.root)
      File.write!(Path.join(ctx.root, "watchdog"), "garbage")
      assert launch(ctx).outcome == {:ok, :clean}
    end

    test "an unreadable watchdog file runs bundled code and refuses installs", ctx do
      stable_install(ctx, "good")
      path = Path.join(ctx.root, "watchdog")
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o600) end)

      app = processes(ctx)

      assert Boot.run(
               store: app.store,
               watchdog: app.watchdog,
               gate: nil,
               verify: ctx.verify,
               poller: nil
             ) == :ok

      assert Store.active(app.store) == nil
      assert {:error, {:watchdog_unreadable, :eacces}} = try_install(ctx, app, "next")
    end

    test "if the watchdog itself is gone, the boot still runs bundled code", ctx do
      stable_install(ctx, "good")
      app = processes(ctx)

      assert Boot.run(
               store: app.store,
               watchdog: :no_such_watchdog,
               gate: nil,
               verify: ctx.verify,
               poller: nil
             ) ==
               :ok

      assert Store.active(app.store) == nil
    end

    test "rejections are never forgotten, however many there are", ctx do
      stable_install(ctx, "good")

      rejected =
        for i <- 1..25 do
          id = install(ctx, launch(ctx), "bad #{i}")
          launch(ctx)
          assert launch(ctx).outcome == {:ok, :rolled_back}
          id
        end

      app = launch(ctx)
      assert Enum.all?(rejected, &Watchdog.rejected?(app.watchdog, &1))
      assert try_install(ctx, app, "bad 1") == {:ok, :rejected}
    end
  end

  test "random launch/install/idle sequences keep the watchdog invariants", ctx do
    for seed <- 1..25 do
      :rand.seed(:exsss, {seed, seed, seed})
      acc = run_sequence(%{ctx | root: Path.join(ctx.root, "seed#{seed}")}, 14)
      assert acc.rollbacks <= acc.installs
    end
  end

  # Each step is one launch, then up to two install attempts and maybe first
  # idle, in random order. Invariants on every launch: a manifest is rolled
  # back at most once and never comes back; one that reached first idle
  # after booting is never rolled back; a rollback never lands on a manifest
  # that hasn't reached first idle.
  defp run_sequence(ctx, steps) do
    initial = %{installs: 0, rollbacks: 0, rolled_back: MapSet.new(), vouched: MapSet.new()}

    Enum.reduce(1..steps, initial, fn step, acc ->
      app = launch(ctx)
      assert {:ok, _} = app.outcome
      booted = Store.active_id(app.store)
      acc = record_rollback(app, booted, acc)

      refute booted != nil and MapSet.member?(acc.rolled_back, booted)

      [:install, :install, :idle]
      |> Enum.shuffle()
      |> Enum.reduce(acc, fn
        :install, acc ->
          maybe(acc, fn acc ->
            case try_install(ctx, app, "#{step}-#{:rand.uniform(1_000_000)}") do
              {:ok, :installed} -> %{acc | installs: acc.installs + 1}
              {:ok, :deferred} -> acc
            end
          end)

        :idle, acc ->
          maybe(acc, fn acc ->
            Watchdog.mark_stable(app.watchdog)
            if booted, do: %{acc | vouched: MapSet.put(acc.vouched, booted)}, else: acc
          end)
      end)
    end)
  end

  defp record_rollback(%{outcome: {:ok, :rolled_back}} = app, landed, acc) do
    %{rolled_back: gone} = Watchdog.take_notice(app.watchdog)
    refute MapSet.member?(acc.vouched, gone)
    refute MapSet.member?(acc.rolled_back, gone)
    assert landed == nil or MapSet.member?(acc.vouched, landed)
    %{acc | rollbacks: acc.rollbacks + 1, rolled_back: MapSet.put(acc.rolled_back, gone)}
  end

  defp record_rollback(_app, _landed, acc), do: acc

  defp maybe(acc, fun), do: if(:rand.uniform(2) == 1, do: fun.(acc), else: acc)

  describe "boot loading" do
    # Compiled to real .beams, then unloaded: reachable only via the store.
    defp compile_unloaded(source) do
      {modules, _} = Code.with_diagnostics([log: false], fn -> Code.compile_string(source) end)

      for {module, binary} <- modules do
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
        {module, binary}
      end
    end

    defp activate_local(ctx, app, modules) do
      for {_module, binary} <- modules, do: :ok = Store.put_blob(app.store, sha(binary), binary)

      b =
        body(
          ctx,
          Enum.map(modules, fn {module, binary} -> {Manifest.module_key(module), binary} end)
        )

      {:ok, manifest} = ctx.verify.(b)
      :ok = Store.activate(app.store, b, manifest, Store.active_id(app.store))
    end

    defp boot(ctx, extra \\ []) do
      app = processes(ctx)

      Boot.run(
        [
          store: app.store,
          watchdog: app.watchdog,
          gate: nil,
          verify: ctx.verify,
          poller: nil,
          stable_after: 60_000
        ] ++ extra
      )
    end

    test "loads delivered modules already on the device, callees before an @on_load caller",
         ctx do
      n = System.unique_integer([:positive])

      # "A" sorts before "Z", so a naive pass would load the caller first and
      # its @on_load would hit an undefined delivered-only callee.
      [{callee, _} = z] =
        compile_unloaded("defmodule MobDeliverBoot#{n}.Z do def ready, do: :ok end")

      [a] =
        compile_unloaded("""
        defmodule MobDeliverBoot#{n}.A do
          @on_load :setup
          def setup, do: #{inspect(callee)}.ready()
          def v, do: :delivered
        end
        """)

      activate_local(ctx, processes(ctx), [a, z])

      assert boot(ctx) == :ok
      {caller, _} = a
      assert caller.v() == :delivered
    end

    test "an @on_load that never returns can't hold the app's boot", ctx do
      n = System.unique_integer([:positive])
      flag = {:mob_deliver_boot_hang, n}

      [{module, _} = hanging] =
        compile_unloaded("""
        defmodule MobDeliverBoot#{n}.Hang do
          @on_load :setup
          def setup do
            if :persistent_term.get(#{inspect(flag)}, false), do: receive(do: (:never -> :ok)), else: :ok
          end
        end
        """)

      activate_local(ctx, processes(ctx), [hanging])
      :persistent_term.put(flag, true)
      on_exit(fn -> :persistent_term.erase(flag) end)

      {micros, result} = :timer.tc(fn -> boot(ctx, load_timeout: 100) end)
      assert result == :ok
      assert micros < 2_000_000
      refute :code.is_loaded(module)

      # The pending load was cancelled, not merely abandoned: nothing queues
      # behind it.
      assert {:ok, _} = Task.yield(Task.async(fn -> Code.ensure_loaded(module) end), 1_000)
    end

    test "cancelling a stuck @on_load kills its runner only — even if it tail-called away", ctx do
      n = System.unique_integer([:positive])
      flag = {:mob_deliver_boot_tail, n}

      {:module, waiter, _, _} =
        defmodule :"Elixir.MobDeliverBoot#{n}.Waiter" do
          def forever, do: receive(do: (:never -> :ok))
        end

      [{module, _} = delivered] =
        compile_unloaded("""
        defmodule MobDeliverBoot#{n}.Tail do
          @on_load :setup
          def setup, do: if(:persistent_term.get(#{inspect(flag)}, false), do: #{inspect(waiter)}.forever(), else: :ok)
          def idle, do: receive(do: (:stop -> :ok))
        end
        """)

      # The version already on the device, with a worker parked in it.
      Code.compile_string(
        "defmodule #{inspect(module)} do def idle, do: receive(do: (:stop -> :ok)) end"
      )

      worker = spawn(fn -> module.idle() end)

      activate_local(ctx, processes(ctx), [delivered])
      :persistent_term.put(flag, true)
      on_exit(fn -> :persistent_term.erase(flag) end)

      assert boot(ctx, load_timeout: 100) == :ok
      assert Process.alive?(worker)
      assert {:ok, _} = Task.yield(Task.async(fn -> Code.ensure_loaded(module) end), 1_000)
    end

    test "boot skips a module whose @on_load someone else has pending, leaving theirs alone",
         ctx do
      n = System.unique_integer([:positive])
      gate = {:mob_deliver_boot_other, n}

      [{module, binary} = delivered] =
        compile_unloaded("""
        defmodule MobDeliverBoot#{n}.Busy do
          @on_load :setup
          def setup, do: wait()
          defp wait do
            if :persistent_term.get(#{inspect(gate)}, :open) == :held, do: (Process.sleep(10); wait()), else: :ok
          end
        end
        """)

      activate_local(ctx, processes(ctx), [delivered])
      :persistent_term.put(gate, :held)
      on_exit(fn -> :persistent_term.erase(gate) end)

      theirs = Task.async(fn -> :code.load_binary(module, ~c"theirs", binary) end)
      Process.sleep(50)

      {micros, result} = :timer.tc(fn -> boot(ctx, load_timeout: 100) end)
      assert result == :ok
      assert micros < 1_000_000

      :persistent_term.put(gate, :open)
      assert Task.await(theirs) == {:module, module}
    end

    test "a raising verifier can't crash boot", ctx do
      assert boot(ctx, verify: fn _ -> raise "boom" end) == :ok
    end
  end
end
