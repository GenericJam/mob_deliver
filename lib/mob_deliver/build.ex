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
  `:ok` if the active manifest `id` still fits the bundled code;
  `{:adopt, base}` if its base wasn't recorded (installed by an older
  mob_deliver) but every delivered module it shares with the binary is
  identical to the bundled one (nothing newer would be overridden);
  `{:stale, pairs}` with the delivered `key => sha` whose bundled version
  changed (or, with no recorded base, differs from the delivered one).
  """
  @spec check(Store.server(), Store.manifest_id(), Manifest.t(), Bundled.index()) ::
          :ok | {:adopt, Store.base()} | {:stale, pairs()}
  def check(store, id, %Manifest{modules: modules} = manifest, index) do
    now = base_of(manifest, index)

    case Store.base(store, id) do
      nil ->
        differing =
          for {key, md5} <- now,
              delivered_md5(store, modules[key]) not in [md5, :not_local],
              do: key

        if differing == [], do: {:adopt, now}, else: {:stale, Map.take(modules, differing)}

      base ->
        # A module bundled now with another fingerprint than at install, or
        # one that wasn't bundled then: bundled code newer than the manifest.
        changed = for {key, md5} <- now, Map.get(base, key) != md5, do: key
        if changed == [], do: :ok, else: {:stale, Map.take(modules, changed)}
    end
  end

  # A delivered module whose blob isn't on the device can't override the
  # bundled one (the bundled one is loaded first and resolve/1 leaves loaded
  # modules alone), so it can't be newer-overriding either.
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
