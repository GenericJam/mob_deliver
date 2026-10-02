defmodule MobDeliver.Restart do
  @moduledoc false
  # Whether the active manifest only takes full effect at the next launch:
  # a module it delivers is loaded in this session with different code
  # (bundled code, or another manifest's version). Loaded modules are never
  # swapped mid-session (ADR "Updates and relaunches"); modules not loaded
  # yet already take the active manifest's version on first use.

  alias MobDeliver.{Bundled, Manifest, Store}

  @spec required?(Store.server()) :: boolean()
  def required?(store) do
    case Store.active(store) do
      {_id, %Manifest{modules: modules}} -> Enum.any?(modules, &stale_in_session?(store, &1))
      nil -> false
    end
  end

  # No atom for the key: nothing loaded references it, so it isn't loaded.
  defp stale_in_session?(store, {key, sha}) do
    with {:ok, module} <- Manifest.existing_module(key),
         {:file, loaded_from} <- :code.is_loaded(module),
         false <- to_string(loaded_from) == Store.blob_path(store, sha) do
      different_code?(store, module, sha)
    else
      _ -> false
    end
  end

  # Loaded from elsewhere, but maybe the very same code (published from
  # the source the binary was built from).
  defp different_code?(store, module, sha) do
    with {:ok, binary} <- Store.read_blob(store, sha),
         {:ok, delivered} <- Bundled.md5(binary) do
      Base.encode16(module.module_info(:md5), case: :lower) != delivered
    else
      # Not on the device: a relaunch wouldn't load it either (the next
      # update check fetches it).
      _ -> false
    end
  end
end
