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
  (lower `issued_at`) can't replace a newer one to lift the gate.

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
      [{:latest, manifest}] ->
        evaluate(
          manifest,
          Keyword.get_lazy(opts, :app_version, &Config.app_version/0),
          Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        )

      [] ->
        :ok
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
  Records a freshly verified manifest (body + parse) if it's at least as
  new as the current one. It governs the gate from now on even if
  persisting it fails (then `{:error, _}` is returned and the next launch
  falls back to the last persisted one).
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
        Keyword.get(opts, :on_change, fn _status -> MobDeliver.GateNavigation.request() end)
    }

    load(s, Keyword.get_lazy(opts, :verify, &MobDeliver.Boot.verifier/0))
    {:ok, s}
  end

  # Runs at application start: a failure here must leave the gate open
  # rather than take the supervisor down.
  defp load(s, verify) do
    with {:ok, body} <- Disk.read(path(s)),
         {:ok, manifest} <- verify.(body) do
      :ets.insert(s.table, {:latest, manifest})
      warn_uncomparable(manifest, s.app_version)
    else
      {:error, :missing} ->
        :ok

      {:error, reason} ->
        Logger.warning("mob_deliver: stored update-gate manifest rejected (#{inspect(reason)})")
    end
  catch
    kind, reason ->
      Logger.warning("mob_deliver: update gate not loaded (#{inspect({kind, reason})})")
  end

  @impl true
  def handle_call({:record, body, manifest}, _from, s) do
    current =
      case :ets.lookup(s.table, :latest) do
        [{:latest, current}] -> current
        [] -> nil
      end

    if current == nil or DateTime.compare(manifest.issued_at, current.issued_at) != :lt do
      # A verified floor applies at once, persisted or not.
      :ets.insert(s.table, {:latest, manifest})
      warn_uncomparable(manifest, s.app_version)
      report_change(s, current, manifest)
      {:reply, Disk.atomic_write(path(s), body), s}
    else
      {:reply, :ok, s}
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
  defp path(s), do: Path.join(Store.root(s.store), "gate.json")
end
