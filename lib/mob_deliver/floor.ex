defmodule MobDeliver.Floor do
  @moduledoc false
  # The replay floor (MOB-382). Every signed manifest stays valid forever,
  # so a server the app is pointed at, or a man-in-the-middle on a
  # plain-HTTP endpoint, could serve an older one and bring back code a
  # later publish replaced. Nothing older than the newest manifest this
  # device has verified is installed (MobDeliver.Installer) or used for a
  # JIT refresh (MobDeliver.Refresh).
  #
  # The mark is the update gate's record (MobDeliver.Gate.newest/1): the
  # newest verified manifest, installed or not, persisted signed and
  # re-verified at boot. The active slot counts too, so a lost or
  # unverifiable gate file still can't take the device below what it runs.
  # A watchdog rollback moves the active slot back but never the gate's
  # record, so it doesn't lower the mark; and since it reinstates a slot
  # rather than installing, it isn't checked here. The active manifest
  # itself always passes: the device already runs it, so after a rollback
  # the server serving it again is neither installed (`:current`) nor
  # reported as a replay by the JIT refresh.
  #
  # Equal issued_at: the same manifest (same content id) passes, so a
  # re-fetch is a no-op for the caller to recognise; a different manifest
  # with the same issued_at doesn't (it isn't newer than the mark).

  require Logger

  alias MobDeliver.{Gate, Manifest, Store}

  @typedoc "Why a manifest was refused: the newest one this device has verified."
  @type downgrade :: %{
          id: Store.manifest_id(),
          issued_at: DateTime.t(),
          newest_id: Store.manifest_id(),
          newest_issued_at: DateTime.t()
        }

  @doc """
  `:ok` if `manifest` (content id `id`) is at or above the floor, else
  `{:error, {:downgrade, info}}`, logged. `opts`: `:gate`, `:store`.
  """
  @spec check(Store.manifest_id(), Manifest.t(), keyword()) ::
          :ok | {:error, {:downgrade, downgrade()}}
  def check(id, %Manifest{} = manifest, opts) do
    case Store.active(opts[:store]) do
      {^id, _active} ->
        :ok

      active ->
        [Gate.newest(opts[:gate]), active]
        |> Enum.find(&below?(id, manifest, &1))
        |> case do
          nil -> :ok
          {newest_id, newest} -> refuse(id, manifest, newest_id, newest)
        end
    end
  end

  defp below?(_id, _manifest, nil), do: false

  defp below?(id, manifest, {mark_id, mark}) do
    case DateTime.compare(manifest.issued_at, mark.issued_at) do
      :lt -> true
      :eq -> id != mark_id
      :gt -> false
    end
  end

  defp refuse(id, manifest, newest_id, newest) do
    Logger.error(
      "mob_deliver: manifest #{id} (issued_at #{DateTime.to_iso8601(manifest.issued_at)}) " <>
        "isn't newer than manifest #{newest_id} (issued_at " <>
        "#{DateTime.to_iso8601(newest.issued_at)}), the newest this device has verified; " <>
        "not used (an old signed manifest replayed, or a publish with an older issued_at)"
    )

    {:error,
     {:downgrade,
      %{
        id: id,
        issued_at: manifest.issued_at,
        newest_id: newest_id,
        newest_issued_at: newest.issued_at
      }}}
  end
end
