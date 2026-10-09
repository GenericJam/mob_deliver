defmodule MobDeliver.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  mob_deliver has no native code; its real path is its processes and the
  content-addressed store on the device's data dir. The test checks that the
  `:mob_deliver` application is running (mob >= 0.9.6 starts plugin
  applications before `on_start`; without it every call would exit and the
  router hook would refuse navigation), reads `MobDeliver.state/0` the way a
  diagnostics screen does, then writes one probe blob through
  `MobDeliver.Store.put_blob/3`, reads it back hash-verified with
  `read_blob/2`, and deletes it. That exercises `Mob.data_dir/0`, the atomic
  write and the hash check on the real filesystem; it never touches the
  active manifest, the probation state or an update check.
  """
  @behaviour Mob.Plugin.SelfTest

  alias MobDeliver.Store

  @impl true
  def run(_ctx) do
    case MobDeliver.state() do
      %{running: false} ->
        {:fail,
         "the :mob_deliver application is not running (mob >= 0.9.6 starts plugin " <>
           "applications before on_start)"}

      %{running: true} ->
        blob_round_trip()
    end
  end

  defp blob_round_trip do
    probe = "mob_deliver self-test #{System.system_time(:nanosecond)} #{node()}"
    sha = Base.encode16(:crypto.hash(:sha256, probe), case: :lower)
    path = Store.blob_path(Store, sha)

    try do
      with :ok <- Store.put_blob(Store, sha, probe),
           {:ok, ^probe} <- Store.read_blob(Store, sha) do
        :pass
      else
        other ->
          {:fail,
           "store round trip at #{path} returned #{inspect(other)}, expected the probe back"}
      end
    after
      File.rm(path)
    end
  end
end
