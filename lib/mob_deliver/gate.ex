defmodule MobDeliver.Gate do
  @moduledoc """
  The forced-update window: `min_app_version` + `force_update_after` from
  the most recent verified manifest.

    * App at or above `min_app_version` (or no floor) → `:ok`.
    * Below it, before `force_update_after` (or with no deadline) →
      `{:recommended, info}`: show a banner linking to the store.
    * Below it, after `force_update_after` → `{:required, info}`: the app
      boots into `MobDeliver.UpdateRequiredScreen` instead of its own root
      screen, and `resolve/1` refuses to deliver screens.

  The gate follows the newest manifest this device has verified, installed
  or not — a manifest the app is too old for is never installed, but its
  floor must still apply. It's persisted as the signed body and
  re-verified at boot, so it holds offline, and an older signed manifest
  (lower `issued_at`) can't replace a newer one to lift the gate. Of two
  different manifests with the same `issued_at`, the first verified stays.

  The same record is the replay floor for installs and JIT refreshes
  (`newest/1`): nothing older than it is used. See
  `decisions/2026-10-15-replay-floor.md`. So it fails closed:

    * It's kept per app and channel, in two copies
      (`<root>/gate/<key>.json` and `<key>.copy.json`, `key` a hash of
      app and channel), so a build on another channel neither replaces
      nor discards it.
    * `record/3` returns `{:error, _}` unless both copies were written;
      callers then don't use the manifest. A record that couldn't be
      written is retried by every later `record/3` this session.
    * At start the record is the newest manifest that verifies among both
      copies, the `gate.json` older versions wrote, and the store's active
      and previous slots; copies that don't hold it are rewritten. A
      missing, corrupt or unverifiable copy is skipped (logged), never
      treated as a floor of its own, so it can't block updates.

  The app's own version is `config :mob_deliver, :app_version` if set,
  else the native store version from `Mob.Device.app_version()`. If it —
  or the floor — isn't a dotted numeric version, the gate stays open: it's
  an update prompt, not a security boundary. That's logged as a warning
  naming the offending side whenever such a manifest is recorded or
  reloaded.
  """

  use GenServer

  require Logger

  alias MobDeliver.{Config, Disk, Manifest, Store}

  @type info :: %{
          min_app_version: String.t(),
          force_update_after: DateTime.t() | nil,
          app_version: String.t(),
          store_url: String.t() | nil
        }
  @type status :: :ok | {:recommended, info()} | {:required, info()}

  @doc """
  Options: `:name`, `:store` (whose root holds the gate file), `:verify`
  (default: this build's trusted key, app, and channel), `:app_version`
  (this binary's version; default `MobDeliver.Config.app_version/0`),
  `:on_change` (called with the new `t:status/0` when a recorded manifest
  moves this app into or out of `:required`; default: bring navigation in
  line, see `MobDeliver.GateNavigation`). The persisted gate is reloaded
  and re-verified on every start, so a restart never opens it.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc """
  The gate for right now. `:app_version` and `:now` override the config
  and clock (tests).
  """
  @spec status(GenServer.server(), keyword()) :: status()
  def status(server \\ __MODULE__, opts \\ []) do
    case :ets.lookup(table(server), :latest) do
      [{:latest, _id, manifest}] ->
        evaluate(
          manifest,
          Keyword.get_lazy(opts, :app_version, &Config.app_version/0),
          Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        )

      [] ->
        :ok
    end
  end

  @doc """
  The newest manifest this device has verified, with its content id, or
  `nil` before the first (or when the persisted one didn't re-verify).
  """
  @spec newest(GenServer.server()) :: {Store.manifest_id(), Manifest.t()} | nil
  def newest(server \\ __MODULE__) do
    case :ets.lookup(table(server), :latest) do
      [{:latest, id, manifest}] -> {id, manifest}
      [] -> nil
    end
  end

  @doc "Whether `manifest` may be installed on this app version (at or above its floor)."
  @spec installable?(Manifest.t(), String.t() | nil) :: boolean()
  def installable?(%Manifest{min_app_version: nil}, _app_version), do: true

  def installable?(%Manifest{min_app_version: min}, app_version) do
    case compare(app_version, min) do
      {:ok, :lt} -> false
      _ -> true
    end
  end

  @doc """
  Records a freshly verified manifest (body + parse) if it's newer than the
  current one (a later `issued_at`; at an equal `issued_at` the current one
  stays). `:ok` once it's persisted (both copies); `{:error, _}` if it
  couldn't be, and then the caller must not use the manifest: after a
  restart the device wouldn't know it had seen it. It governs the gate (and
  the replay floor) this session either way, and every later call retries
  the write first, returning `{:error, _}` until one succeeds.
  """
  @spec record(GenServer.server(), binary(), Manifest.t()) :: :ok | {:error, term()}
  def record(server \\ __MODULE__, body, %Manifest{} = manifest),
    do: GenServer.call(server, {:record, body, manifest})

  @doc false
  @spec evaluate(Manifest.t(), String.t() | nil, DateTime.t()) :: status()
  def evaluate(%Manifest{min_app_version: nil}, _app_version, _now), do: :ok

  def evaluate(%Manifest{min_app_version: min, force_update_after: deadline}, app_version, now) do
    case compare(app_version, min) do
      {:ok, :lt} ->
        info = %{
          min_app_version: min,
          force_update_after: deadline,
          app_version: app_version,
          store_url: Config.get(:store_url)
        }

        if deadline != nil and DateTime.compare(now, deadline) != :lt,
          do: {:required, info},
          else: {:recommended, info}

      # Either side unparseable (:error) leaves the gate open. That's logged
      # when the manifest is recorded or reloaded, not here: this runs on
      # every navigation.
      _at_or_above_or_uncomparable ->
        :ok
    end
  end

  @doc false
  # Dotted numeric versions, missing segments as 0: "1.4" == "1.4.0".
  @spec compare(String.t() | nil, String.t()) :: {:ok, :lt | :eq | :gt} | :error
  def compare(a, b) do
    with {:ok, a} <- segments(a), {:ok, b} <- segments(b) do
      width = max(length(a), length(b))
      pad = &(&1 ++ List.duplicate(0, width - length(&1)))

      {:ok,
       cond do
         pad.(a) < pad.(b) -> :lt
         pad.(a) > pad.(b) -> :gt
         true -> :eq
       end}
    end
  end

  defp segments(version) when is_binary(version) and version != "" do
    version
    |> String.split(".")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case Integer.parse(part) do
        {n, ""} when n >= 0 -> {:cont, {:ok, [n | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp segments(_), do: :error

  # ── server ──────────────────────────────────────────────────────────────

  @impl true
  def init({name, opts}) do
    :ets.new(table(name), [:named_table, :protected, read_concurrency: true])

    s = %{
      table: table(name),
      store: Keyword.get(opts, :store, Store),
      app_version: Keyword.get_lazy(opts, :app_version, &Config.app_version/0),
      on_change:
        Keyword.get(opts, :on_change, fn _status -> MobDeliver.GateNavigation.request() end),
      # The record in effect, while it isn't persisted: {body, manifest}.
      unsaved: nil
    }

    {:ok, load(s, Keyword.get_lazy(opts, :verify, &MobDeliver.Boot.verifier/0))}
  end

  # Runs at application start: a failure here must leave the gate open
  # rather than take the supervisor down. The record is the newest manifest
  # that verifies among everything stored; a source that doesn't verify is
  # skipped, never trusted as a floor (that could hold back updates forever).
  defp load(s, verify) do
    found =
      for {source, body} <- stored(s),
          manifest = verified(source, body, verify),
          manifest != nil,
          do: {source, Store.manifest_id(body), body, manifest}

    case Enum.reduce(found, nil, &newest_of/2) do
      nil ->
        s

      {source, id, body, manifest} ->
        :ets.insert(s.table, {:latest, id, manifest})
        warn_uncomparable(manifest, s.app_version)
        held = for {{:copy, path}, ^id, _body, _manifest} <- found, do: path

        if copies(s, manifest) -- held == [],
          do: s,
          else: restore(s, source, body, manifest)
    end
  catch
    kind, reason ->
      Logger.warning("mob_deliver: update gate not loaded (#{inspect({kind, reason})})")
      s
  end

  # Every app's and channel's copies, the single gate.json written before
  # records were kept per channel (read, never written), and the store's
  # slots (the manifest the device runs, and the one before it).
  defp stored(s) do
    dir = dir(s)

    names =
      case File.ls(dir) do
        {:ok, names} -> Enum.sort(names)
        {:error, _} -> []
      end

    copies =
      for name <- names,
          String.ends_with?(name, ".json"),
          path = Path.join(dir, name),
          body <- read(path),
          do: {{:copy, path}, body}

    legacy = for body <- read(legacy_path(s)), do: {{:legacy, legacy_path(s)}, body}
    copies ++ legacy ++ for(body <- Store.persisted_bodies(s.store), do: {:slot, body})
  end

  defp read(path) do
    case Disk.read(path) do
      {:ok, body} ->
        [body]

      {:error, :missing} ->
        []

      {:error, reason} ->
        Logger.warning("mob_deliver: update-gate record #{path} unreadable (#{inspect(reason)})")
        []
    end
  end

  defp verified(source, body, verify) do
    case verify.(body) do
      {:ok, manifest} ->
        manifest

      # Another app's or channel's record: kept for when the build is on it again.
      {:error, {mismatch, _}} when mismatch in [:app_mismatch, :channel_mismatch] ->
        nil

      # The store reports its own slots at boot.
      {:error, _reason} when source == :slot ->
        nil

      {:error, reason} ->
        {_, path} = source

        Logger.warning(
          "mob_deliver: stored update-gate manifest #{path} rejected (#{inspect(reason)}); skipped"
        )

        nil
    end
  end

  # The later issued_at; of equal ones, the first found (own copies first).
  defp newest_of(candidate, nil), do: candidate

  defp newest_of({_, _, _, manifest} = candidate, {_, _, _, newest} = acc) do
    if DateTime.after?(manifest.issued_at, newest.issued_at), do: candidate, else: acc
  end

  defp restore(s, source, body, manifest) do
    case source do
      {:legacy, _path} ->
        Logger.info("mob_deliver: update-gate record moved to per-channel copies")

      {:copy, path} ->
        Logger.warning("mob_deliver: update-gate record restored from #{path}")

      :slot ->
        Logger.warning(
          "mob_deliver: update-gate record lost or unverifiable; restored from the store's slots"
        )
    end

    case save(%{s | unsaved: {body, manifest}}) do
      {:ok, s} ->
        s

      {{:error, reason}, s} ->
        Logger.warning("mob_deliver: update-gate record not restored (#{inspect(reason)})")
        s
    end
  end

  @impl true
  def handle_call({:record, body, manifest}, _from, s) do
    id = Store.manifest_id(body)

    {reply, s} =
      case :ets.lookup(s.table, :latest) do
        [{:latest, _current_id, current}] ->
          case DateTime.compare(manifest.issued_at, current.issued_at) do
            :gt -> replace(s, current, id, body, manifest)
            # The same manifest again, an older one, or another with the same
            # issued_at: the newest stays, but its write is retried if it failed.
            _ -> retry(s)
          end

        [] ->
          replace(s, nil, id, body, manifest)
      end

    {:reply, reply, s}
  end

  # Written first, then in effect whether or not the write succeeded: a
  # higher floor in memory only refuses more, and dropping it would let this
  # session use a manifest older than one it has verified. The caller sees
  # the write's result and doesn't use the manifest unless it succeeded.
  defp replace(s, current, id, body, manifest) do
    result = save(%{s | unsaved: {body, manifest}})
    :ets.insert(s.table, {:latest, id, manifest})
    warn_uncomparable(manifest, s.app_version)
    report_change(s, current, manifest)
    result
  end

  defp retry(%{unsaved: nil} = s), do: {:ok, s}
  defp retry(s), do: save(s)

  # Both copies, each written atomically; the second is written even if the
  # first failed, and the first error is returned.
  defp save(%{unsaved: {body, manifest}} = s) do
    case Enum.find(Enum.map(copies(s, manifest), &Disk.atomic_write(&1, body)), &(&1 != :ok)) do
      nil -> {:ok, %{s | unsaved: nil}}
      error -> {error, s}
    end
  end

  # Into or out of :required (recommended counts as open: nothing blocks).
  defp report_change(s, current, manifest) do
    now = DateTime.utc_now()
    before = if current, do: evaluate(current, s.app_version, now), else: :ok
    after_record = evaluate(manifest, s.app_version, now)

    if required?(before) != required?(after_record) do
      try do
        s.on_change.(after_record)
      catch
        kind, reason ->
          Logger.warning(
            "mob_deliver: update-gate change handler failed (#{Exception.format_banner(kind, reason)})"
          )
      end
    end
  end

  defp required?(status), do: match?({:required, _}, status)

  defp warn_uncomparable(%Manifest{min_app_version: nil}, _app_version), do: :ok

  defp warn_uncomparable(%Manifest{min_app_version: min}, app_version) do
    cond do
      segments(min) == :error ->
        Logger.warning(
          "mob_deliver: the manifest's min_app_version #{inspect(min)} isn't a dotted numeric " <>
            "version like \"1.4.0\"; the update gate stays open (fix it where you publish)"
        )

      segments(app_version) == :error ->
        Logger.warning(
          "mob_deliver: this app's version #{inspect(app_version)} isn't a dotted numeric " <>
            "version like \"1.4.0\"; the update gate stays open (set config :mob_deliver, :app_version)"
        )

      true ->
        :ok
    end
  end

  defp table(name) when is_atom(name), do: :"#{name}.table"
  defp dir(s), do: Path.join(Store.root(s.store), "gate")
  defp legacy_path(s), do: Path.join(Store.root(s.store), "gate.json")

  # One key per app and channel: a hash, so neither can name a path.
  defp copies(s, %Manifest{app: app, channel: channel}) do
    key = Base.encode16(:crypto.hash(:sha256, [app, 0, channel]), case: :lower)
    [Path.join(dir(s), key <> ".json"), Path.join(dir(s), key <> ".copy.json")]
  end
end
