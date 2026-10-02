defmodule MobDeliver.Build do
  @moduledoc false
  # Whether a manifest still fits the app binary it runs on. At install,
  # the bundled versions of the modules it delivers are recorded (its
  # base); at boot, if any of them differs now — a new native build or a
  # BEAM push changed bundled code under it — the delivered versions would
  # override code newer than what they were built against, so the manifest
  # is stale for this build. See the ADR's "Builds change under manifests".

  alias MobDeliver.{Bundled, Manifest, Store}

  @type pairs :: %{String.t() => Manifest.sha256()}

  @doc "The base `manifest` lands on: its keys' bundled fingerprints now."
  @spec base_of(Manifest.t(), Bundled.index()) :: Store.base()
  def base_of(%Manifest{modules: modules}, index), do: Bundled.md5s(index, Map.keys(modules))

  @doc """
  Whether manifest `id` (in a store slot) still fits the bundled code:

    * `:ok` — none of the bundled modules it overrides changed since it
      was installed;
    * `{:adopt, base}` — some changed (or its base was never recorded,
      for a manifest installed by an older mob_deliver), but every one of
      them is now identical to the delivered version (a build that ships
      the delivered code): it still fits, record `base` as its base;
    * `{:stale, superseded, unresolved}` — the bundled versions of some
      of its modules changed under it to code other than the delivered
      one: the build outgrew it. `superseded` (`key => sha`) are the
      delivered versions known to differ from the new bundled code, to
      refuse from now on; `unresolved` are the ones whose delivered blob
      isn't on the device (lost or corrupt) to compare, so it can't be
      told whether this build ships them: an install that brings them
      back compares them then (`matches_bundled?/3`).
  """
  @spec check(Store.server(), Store.manifest_id(), Manifest.t(), Bundled.index()) ::
          :ok | {:adopt, Store.base()} | {:stale, pairs(), pairs()}
  def check(store, id, %Manifest{modules: modules} = manifest, index) do
    now = base_of(manifest, index)
    base = Store.base(store, id)

    # Bundled modules that changed under it (all of them if it has no base).
    changed =
      for {key, md5} <- now, base == nil or Map.get(base, key) != md5, do: {key, md5}

    outgrown =
      for {key, md5} <- changed,
          delivered = delivered_md5(store, modules[key]),
          delivered != md5,
          do: {key, delivered}

    cond do
      outgrown != [] ->
        {unresolved, superseded} = Enum.split_with(outgrown, &(elem(&1, 1) == :not_local))
        keys = &Enum.map(&1, fn {key, _} -> key end)
        {:stale, Map.take(modules, keys.(superseded)), Map.take(modules, keys.(unresolved))}

      changed == [] ->
        :ok

      true ->
        {:adopt, now}
    end
  end

  @doc """
  Whether delivered `binary` for `key` would override nothing newer in
  this build: the build doesn't bundle `key`, or bundles exactly that code.
  """
  @spec matches_bundled?(String.t(), binary(), Bundled.index()) :: boolean()
  def matches_bundled?(key, binary, index) do
    case Bundled.md5s(index, [key]) do
      %{^key => bundled} -> Bundled.md5(binary) == {:ok, bundled}
      _not_bundled -> true
    end
  end

  defp delivered_md5(store, sha) do
    case Store.read_blob(store, sha) do
      {:ok, binary} ->
        case Bundled.md5(binary) do
          {:ok, md5} -> md5
          :error -> :unreadable
        end

      {:error, _} ->
        :not_local
    end
  end
end
