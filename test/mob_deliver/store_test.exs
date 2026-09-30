defmodule MobDeliver.StoreTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Manifest, Store, TestPublisher}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: root} do
    {key, private} = TestPublisher.keypair()
    name = :"store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name, root: root}, id: name)

    verify = &Manifest.verify(&1, key, app: "com.example.app", channel: "production")
    %{store: name, root: root, private: private, verify: verify}
  end

  defp sha(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  defp signed_body(private, modules) do
    %{"modules" => Map.new(modules, fn {name, bin} -> {name, "sha256:" <> sha(bin)} end)}
    |> TestPublisher.fields()
    |> TestPublisher.sign(private)
    |> JSON.encode!()
  end

  defp activate!(store, body, verify) do
    {:ok, manifest} = verify.(body)
    :ok = Store.activate(store, body, manifest, Store.active_id(store))
    Store.manifest_id(body)
  end

  defp restart(ctx) do
    name = :"#{ctx.store}_restart_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name, root: ctx.root}, id: name)
    name
  end

  defp write_state(root, state),
    do: File.write!(Path.join(root, "state"), :erlang.term_to_binary(state))

  describe "blobs" do
    test "round-trip only under their own SHA", %{store: store} do
      bin = "beam bytes"

      assert Store.put_blob(store, sha(bin), bin) == :ok
      assert Store.read_blob(store, sha(bin)) == {:ok, bin}
      assert Store.put_blob(store, sha("other"), bin) == {:error, :sha_mismatch}
      assert Store.read_blob(store, sha("never stored")) == {:error, :missing}
    end

    test "SHAs that aren't 64 lowercase hex never reach the filesystem", %{
      store: store,
      root: root
    } do
      for bad <- ["../../state", String.upcase(sha("x")), "abc", nil] do
        assert Store.put_blob(store, bad, "x") == {:error, :invalid_sha}
        assert Store.read_blob(store, bad) == {:error, :invalid_sha}
      end

      assert File.ls!(root) == []
    end

    test "a blob altered on disk reads as corrupt until a valid put replaces it", %{
      store: store,
      root: root
    } do
      bin = "original"
      :ok = Store.put_blob(store, sha(bin), bin)
      File.write!(Path.join([root, "blobs", sha(bin)]), "tampered")

      assert Store.read_blob(store, sha(bin)) == {:error, :corrupt}
      refute Store.has_blob?(store, sha(bin))

      assert Store.put_blob(store, sha(bin), bin) == :ok
      assert Store.read_blob(store, sha(bin)) == {:ok, bin}
    end

    test "concurrent writers of the same SHA all succeed and leave one intact blob",
         %{store: store, root: root} do
      bin = :crypto.strong_rand_bytes(256_000)

      results =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> Store.put_blob(store, sha(bin), bin) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.uniq(results) == [:ok]
      assert Store.read_blob(store, sha(bin)) == {:ok, bin}
      assert File.ls!(Path.join(root, "blobs")) == [sha(bin)]
    end
  end

  describe "active manifest" do
    test "activation indexes modules and survives a restart",
         %{private: private, verify: verify} = ctx do
      first = signed_body(private, [{"MyApp.Home", "v1"}])
      second = signed_body(private, [{"MyApp.Home", "v2"}, {"MyApp.New", "n1"}])

      assert Store.active(ctx.store) == nil
      activate!(ctx.store, first, verify)
      assert Store.lookup(ctx.store, "MyApp.Home") == {:ok, sha("v1")}

      second_id = activate!(ctx.store, second, verify)
      assert Store.lookup(ctx.store, "MyApp.New") == {:ok, sha("n1")}

      restarted = restart(ctx)
      assert Store.active(restarted) == nil
      assert {:ok, %Manifest{}} = Store.boot(restarted, verify)
      assert Store.active_id(restarted) == second_id
      assert Store.lookup(restarted, "MyApp.Home") == {:ok, sha("v2")}
    end

    test "activation based on a stale view of the active slot is rejected",
         %{store: store, private: private, verify: verify} do
      first = signed_body(private, [{"MyApp.Home", "v1"}])
      second = signed_body(private, [{"MyApp.Home", "v2"}])
      {:ok, manifest} = verify.(second)

      activate!(store, first, verify)

      assert Store.activate(store, second, manifest, nil) == {:error, :conflict}
      assert Store.lookup(store, "MyApp.Home") == {:ok, sha("v1")}
    end

    test "a rejected active manifest falls back to the previous one, and that sticks",
         %{private: private, verify: verify} = ctx do
      {_other_key, other_private} = TestPublisher.keypair()
      good = signed_body(private, [{"MyApp.Home", "good"}])
      forged = signed_body(other_private, [{"MyApp.Home", "evil"}])
      write_state(ctx.root, %{active: forged, previous: good})

      assert {:ok, %Manifest{}} = Store.boot(ctx.store, verify)
      assert Store.lookup(ctx.store, "MyApp.Home") == {:ok, sha("good")}

      restarted = restart(ctx)
      Store.boot(restarted, verify)
      assert Store.active_id(restarted) == Store.manifest_id(good)
    end

    test "with no usable manifest boot runs bundled code and a fresh install still works",
         %{private: private, verify: verify} = ctx do
      {_other_key, other_private} = TestPublisher.keypair()
      write_state(ctx.root, %{active: signed_body(other_private, []), previous: nil})

      assert Store.boot(ctx.store, verify) == {:ok, nil}
      assert Store.active_id(ctx.store) == nil

      body = signed_body(private, [{"MyApp.Home", "v1"}])
      {:ok, manifest} = verify.(body)
      assert Store.activate(ctx.store, body, manifest, Store.active_id(ctx.store)) == :ok
    end

    test "if the boot fallback can't be persisted, the published token still works for the next install",
         %{private: private, verify: verify} = ctx do
      {_other_key, other_private} = TestPublisher.keypair()
      good = signed_body(private, [{"MyApp.Home", "good"}])
      write_state(ctx.root, %{active: signed_body(other_private, []), previous: good})

      File.chmod!(ctx.root, 0o500)
      on_exit(fn -> File.chmod(ctx.root, 0o700) end)
      assert {:ok, %Manifest{}} = Store.boot(ctx.store, verify)
      assert Store.active_id(ctx.store) == Store.manifest_id(good)

      File.chmod!(ctx.root, 0o700)
      next = signed_body(private, [{"MyApp.Home", "next"}])
      {:ok, manifest} = verify.(next)
      assert Store.activate(ctx.store, next, manifest, Store.active_id(ctx.store)) == :ok
      assert Store.lookup(ctx.store, "MyApp.Home") == {:ok, sha("next")}
    end

    test "untrusted state contents never crash boot or reach the filesystem",
         %{verify: verify} = ctx do
      decoy =
        Path.join(Path.dirname(ctx.root), "decoy-#{System.unique_integer([:positive])}.json")

      File.write!(decoy, "keep me")

      for state <- [
            %{active: 123, previous: nil},
            %{active: "../../" <> Path.basename(decoy, ".json"), previous: nil},
            %{active: nil},
            [:not, :a, :map]
          ] do
        write_state(ctx.root, state)
        assert Store.boot(ctx.store, verify) == {:ok, nil}
      end

      File.write!(Path.join(ctx.root, "state"), "garbage")
      assert Store.boot(ctx.store, verify) == {:ok, nil}
      assert File.read!(decoy) == "keep me"
    end

    test "re-booting a store keeps its active entry visible throughout",
         %{private: private, verify: verify} = ctx do
      activate!(ctx.store, signed_body(private, [{"MyApp.Home", "v1"}]), verify)
      test_pid = self()

      slow_verify = fn body ->
        send(test_pid, {:verifying, self()})
        receive do: (:continue -> verify.(body))
      end

      booting = Task.async(fn -> Store.boot(ctx.store, slow_verify) end)
      assert_receive {:verifying, verifier}
      assert Store.lookup(ctx.store, "MyApp.Home") == {:ok, sha("v1")}
      send(verifier, :continue)
      assert {:ok, %Manifest{}} = Task.await(booting)
    end
  end
end
