defmodule MobDeliver.Build do
  @moduledoc false
  # Whether a manifest still fits the app binary it runs on. At install,
  # the bundled versions of the modules it delivers are recorded (its
  # base); at boot, if any of them differs now — a new native build or a
  # BEAM push changed bundled code under it — the delivered versions would
  # override code newer than what they were built against, so the manifest
  # is stale for this build. See the ADR's "Builds change under manifests".

  alias MobDeliver.{Bundled, Fetcher, Manifest, Store, Watchdog}

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
      back compares them then (`settle_unresolved/2`).
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
  Whether a manifest that isn't in a slot (fetched for an install or for
  a JIT refresh) may run on this build: `{:ok, :stale_for_build}` if it
  ships a version a newer build superseded, else `settle_unresolved/2`.
  """
  @spec fits(Manifest.t(), keyword()) :: :ok | {:ok, :stale_for_build} | {:error, term()}
  def fits(%Manifest{} = manifest, opts) do
    if Watchdog.superseded?(opts[:watchdog], manifest),
      do: {:ok, :stale_for_build},
      else: settle_unresolved(manifest, opts)
  end

  @doc """
  Compares the unresolved versions `manifest` ships — versions of a
  manifest this build outgrew whose blobs weren't on the device to compare
  when it did (`Watchdog.supersede/3`) — with the bundled code, fetching
  their blobs (`opts` as for `MobDeliver.Fetcher.ensure_blob/2`, plus
  `:watchdog`). All identical to this build's bundled code (or no longer
  bundled): nothing newer is overridden, they're cleared, `:ok`.
  Otherwise they're superseded like any outgrown version:
  `{:ok, :stale_for_build}`. A blob that can't be fetched leaves them
  unresolved: `{:error, {:prefetch_failed, sha, reason}}`.
  """
  @spec settle_unresolved(Manifest.t(), keyword()) ::
          :ok | {:ok, :stale_for_build} | {:error, term()}
  def settle_unresolved(%Manifest{} = manifest, opts) do
    case Watchdog.unresolved(opts[:watchdog], manifest) do
      [] -> :ok
      pending -> compare_unresolved(pending, Bundled.index(), opts)
    end
  end

  defp compare_unresolved(pending, index, opts) do
    compared =
      Enum.reduce_while(pending, {[], []}, fn {key, sha} = pair, {same, newer} ->
        case Fetcher.ensure_blob(sha, opts) do
          {:ok, binary} ->
            if matches_bundled?(key, binary, index),
              do: {:cont, {[pair | same], newer}},
              else: {:cont, {same, [pair | newer]}}

          {:error, reason} ->
            {:halt, {:error, {:prefetch_failed, sha, reason}}}
        end
      end)

    case compared do
      {:error, _} = error ->
        error

      {same, []} ->
        Watchdog.resolve(opts[:watchdog], same)

      {_same, newer} ->
        with :ok <- Watchdog.supersede(opts[:watchdog], newer), do: {:ok, :stale_for_build}
    end
  end

  # Overrides nothing newer: the build doesn't bundle `key`, or bundles
  # exactly that code.
  defp matches_bundled?(key, binary, index) do
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
