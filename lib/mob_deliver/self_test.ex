defmodule MobDeliver.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  mob_deliver has no native code; its real path is its processes and the
  content-addressed store under the device's data dir
  (`MobDeliver.Config.root/0`). The test fails if the `:mob_deliver`
  application is not running (mob >= 0.9.6 starts plugin applications
  before `on_start`; without it every call would exit and the router hook
  would refuse navigation), reads `MobDeliver.state/0` the way a diagnostics
  screen does, then writes one probe blob through a private
  `MobDeliver.Store` on a scratch dir beside the real store, reads it back
  hash-verified with `read_blob/2`, and deletes the dir. A private store
  keeps the probe out of the boot-time blob GC's way and leaves nothing
  behind. A host that never configured the plugin (`config :mob_deliver`
  missing or not shipped to the device) is a skip with the missing keys:
  the plugin is inert there, which is not a bug in it.
  """
  @behaviour Mob.Plugin.SelfTest

  alias MobDeliver.{Config, Store}

  @impl true
  def run(_ctx) do
    case MobDeliver.state() do
      %{running: false} ->
        {:fail,
         "the :mob_deliver application is not running (mob >= 0.9.6 starts plugin " <>
           "applications before on_start)"}

      %{running: true} ->
        case Config.missing() do
          [] ->
            if MobDeliver.Manifest.valid_key?(Config.trusted_publish_key()),
              do: blob_round_trip(),
              else:
                {:fail,
                 "config :mob_deliver, :trusted_publish_key is not a valid ed25519 key; " <>
                   "the plugin skips its boot"}

          missing ->
            {:skip,
             "not configured on this host: #{Enum.map_join(missing, ", ", &inspect/1)} unset " <>
               "in config :mob_deliver (or the app config did not reach the device)"}
        end
    end
  end

  defp blob_round_trip do
    root = Path.join(Store.root(Store), "selftest-#{System.unique_integer([:positive])}")
    probe = "mob_deliver self-test #{System.system_time(:nanosecond)} #{node()}"
    sha = Base.encode16(:crypto.hash(:sha256, probe), case: :lower)

    case Store.start_link(name: :mob_deliver_selftest_store, root: root) do
      {:ok, pid} ->
        try do
          with :ok <- Store.put_blob(:mob_deliver_selftest_store, sha, probe),
               {:ok, ^probe} <- Store.read_blob(:mob_deliver_selftest_store, sha) do
            :pass
          else
            other ->
              {:fail,
               "store round trip under #{root} returned #{inspect(other)}, expected the probe back"}
          end
        after
          GenServer.stop(pid)
          File.rm_rf(root)
        end

      {:error, reason} ->
        {:fail, "could not start a store under #{root}: #{inspect(reason)}"}
    end
  end
end
