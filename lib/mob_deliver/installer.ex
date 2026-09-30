defmodule MobDeliver.Installer do
  @moduledoc false
  # One update check: fetch the signed manifest, record it for the update
  # gate, and install it through the watchdog's install transaction. See
  # MobDeliver.check/0.

  require Logger

  alias MobDeliver.{
    Client,
    Config,
    Fetcher,
    Gate,
    Loader,
    Manifest,
    SingleFlight,
    Store,
    Watchdog
  }

  @type outcome :: :current | :installed | :rejected | :deferred | :below_min_version
  @type opts :: [
          store: Store.server(),
          watchdog: GenServer.server(),
          gate: GenServer.server(),
          single_flight: GenServer.server(),
          client_opts: keyword(),
          app_version: String.t() | nil
        ]

  @spec check(opts()) :: {:ok, outcome()} | {:error, term()}
  def check(opts \\ []) do
    opts = defaults(opts)

    with {:ok, manifest, body} <- Client.fetch_manifest(opts[:client_opts]) do
      # The gate follows the newest verified manifest, installable or not.
      with {:error, reason} <- Gate.record(opts[:gate], body, manifest) do
        Logger.warning("mob_deliver: could not record update-gate manifest (#{inspect(reason)})")
      end

      id = Store.manifest_id(body)
      expected = Store.active_id(opts[:store])

      # Cheap pre-checks so nothing is downloaded for an install that can't
      # happen; Watchdog.install/4 re-checks the watchdog ones atomically.
      cond do
        id == expected -> {:ok, :current}
        not Gate.installable?(manifest, opts[:app_version]) -> {:ok, :below_min_version}
        Watchdog.rejected?(opts[:watchdog], id, manifest) -> {:ok, :rejected}
        not Watchdog.ready_to_install?(opts[:watchdog]) -> {:ok, :deferred}
        true -> install(id, body, manifest, expected, opts)
      end
    end
  end

  defp defaults(opts) do
    opts
    |> Keyword.put_new(:store, Store)
    |> Keyword.put_new(:watchdog, Watchdog)
    |> Keyword.put_new(:gate, Gate)
    |> Keyword.put_new(:single_flight, SingleFlight)
    |> Keyword.put_new_lazy(:client_opts, &Config.client_opts/0)
    |> Keyword.put_new_lazy(:app_version, &Config.app_version/0)
  end

  # Everything the next boot will load is on disk before the slot switches:
  # a half-fetched update never becomes active.
  defp install(id, body, manifest, expected, opts) do
    with :ok <- prefetch(manifest, opts),
         {:ok, :installed} = installed <-
           Watchdog.install(opts[:watchdog], body, manifest, expected) do
      Logger.info(
        "mob_deliver: installed manifest #{id}; modules this session already runs " <>
          "switch to it at the next launch, others load from it on first use"
      )

      installed
    end
  end

  # New versions of modules the device already runs (delivered ones in the
  # active manifest, or bundled ones on the code path), delivered modules
  # that code loaded on the device calls (a bundled screen calling a
  # delivered helper), plus every delivered module those call: boot loads
  # them all, so the next launch — a probation launch — doesn't have to
  # download them while its first screen mounts (even offline). Modules
  # nothing on the device calls stay JIT (resolve/1) so first launches stay
  # small; a module merely named (push_screen(socket, SomeScreen)) is JIT.
  defp prefetch(%Manifest{modules: modules}, opts) do
    current =
      case Store.active(opts[:store]) do
        {_id, %Manifest{modules: active}} -> active
        nil -> %{}
      end

    changed =
      for {key, sha} <- modules, Map.get(current, key) != sha, on_device?(key, current), do: key

    (changed ++ called_by_loaded_code(modules, current))
    |> fetch_closure(MapSet.new(), modules, opts)
  end

  # Delivered keys not on the device that some loaded module imports (calls
  # remotely). Loading a module creates the atoms it imports, so a key
  # without an atom can't be imported by anything loaded — that filter
  # keeps the scan of loaded modules' import chunks to the rare install
  # that has candidates.
  defp called_by_loaded_code(modules, current) do
    candidates =
      for {key, _sha} <- modules,
          not Map.has_key?(current, key),
          {:ok, module} <- [Manifest.existing_module(key)],
          :code.which(module) == :non_existing,
          into: MapSet.new(),
          do: module

    if MapSet.size(candidates) == 0 do
      []
    else
      :code.all_loaded()
      |> Enum.flat_map(fn
        {_module, file} when is_list(file) and file != [] -> imports_from_file(file)
        _preloaded_or_in_memory -> []
      end)
      |> Enum.filter(&MapSet.member?(candidates, &1))
      |> Enum.uniq()
      |> Enum.map(&Manifest.module_key/1)
    end
  end

  defp imports_from_file(file) do
    case :beam_lib.chunks(file, [:imports]) do
      {:ok, {_module, [imports: imports]}} -> Enum.map(imports, &elem(&1, 0))
      {:error, :beam_lib, _} -> []
    end
  end

  defp fetch_closure([], _seen, _modules, _opts), do: :ok

  defp fetch_closure([key | rest], seen, modules, opts) do
    if MapSet.member?(seen, key) do
      fetch_closure(rest, seen, modules, opts)
    else
      sha = Map.fetch!(modules, key)

      case Fetcher.ensure_blob(sha, opts) do
        {:ok, binary} ->
          callees =
            binary
            |> Loader.imported_modules()
            |> Enum.map(&Manifest.module_key/1)
            |> Enum.filter(&Map.has_key?(modules, &1))

          fetch_closure(callees ++ rest, MapSet.put(seen, key), modules, opts)

        {:error, reason} ->
          {:error, {:prefetch_failed, sha, reason}}
      end
    end
  end

  # No atom is created for a key this VM has never heard of — such a module
  # can't be bundled — so arbitrary manifest keys can't grow the atom table.
  defp on_device?(key, current) do
    Map.has_key?(current, key) or
      (match?({:ok, module} when module != nil, Manifest.existing_module(key)) and
         :code.which(elem(Manifest.existing_module(key), 1)) != :non_existing)
  end
end
