defmodule MobDeliver.Watchdog do
  @moduledoc """
  Probation for installed manifests: one whose first boot never reaches
  first idle is rolled back on the next launch.

  State lives in `<store root>/watchdog` and changes only by durable write
  — the in-memory copy is updated after the write succeeds, never ahead.

    1. **Install** (`install/4`) is one serialized transaction: refuse a
       manifest that is rejected or already active, **defer** while any
       install is still unproven (`armed` set — the active manifest hasn't
       passed a probation boot yet), otherwise arm `armed: X, boots: 0`
       and activate X against the caller's compare-and-set token. A failed
       activation disarms again; a crash in between leaves a beacon for a
       non-active manifest, discarded by the next boot.
    2. **Boot** with X active and armed: `boots: 0 → 1`. If that can't be
       written, the boot runs bundled code — delivered code never runs
       without a durable probation record.
    3. **First idle** (`mark_stable/1`): disarm, but only the manifest this
       session booted. A manifest installed during the session hasn't
       booted yet, so this session's idle vouches nothing about it.
    4. **Next boot** finds X armed with `boots: 1` → the previous boot died
       before first idle → X is recorded as `rejected` (with a one-time
       notice), then the store rolls back to previous — which is always a
       proven manifest or bundled code, since installs wait for proof.

  A rejection is recorded by **code** for **this app version**: the
  manifest's `Manifest.code_id/1` (its module → SHA map) paired with the
  native app version. It refuses any manifest with the same modules on
  that version, whatever its `issued_at` or update window — the exact
  signed manifest included. On another app version (a store update) the
  same content gets a fresh probation; once it passes there, its
  rejections under other versions are dropped. Rejections recorded by
  0.1.0 are exact manifest ids (`rejected`) and stay unconditional: their
  exact manifest is refused on every version, while the same modules
  re-published get one more probation boot.

  Rejections are authoritative: any boot with a rejected manifest active
  rolls it back (so a crash mid-rollback finishes next time) and it's never
  installed again; if the app was updated in between, it boots on
  probation instead. After a rollback nothing is armed, so repeated crashes
  never ping-pong between slots. Any failure to record or perform a
  rollback returns `{:error, _}` and the boot runs bundled code.

  `first_idle?/1` tells whether this VM has reached first idle (the root
  screen's first frame) — until then, `MobDeliver.resolve/1` runs nothing
  that isn't under probation.
  """

  use GenServer

  require Logger

  alias MobDeliver.{Config, Disk, Manifest, Store}

  @type server :: GenServer.server()
  @type notice :: %{rolled_back: Store.manifest_id(), at: DateTime.t()}

  @empty %{armed: nil, boots: 0, rejected: [], rejected_code: [], notice: nil}

  @typedoc "A rejection: `Manifest.code_id/1` and the native app version it failed on."
  @type code_rejection :: {String.t(), String.t() | nil}

  @doc """
  Options: `:name`, `:store` (default `MobDeliver.Store`), `:app_version`
  (the native version code ids are computed with; default
  `MobDeliver.Config.app_version/0`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Installs a verified manifest: arm + activate as one step. `expected` is
  the `Store.active_id/1` the caller prepared the install against (e.g.
  prefetched blobs for).
  """
  @spec install(server(), binary(), Manifest.t(), Store.manifest_id() | nil) ::
          {:ok, :installed | :current | :rejected | :deferred} | {:error, term()}
  def install(server, body, %Manifest{} = manifest, expected),
    do: GenServer.call(server, {:install, body, manifest, expected})

  @doc "Whether an install could proceed now (nothing unproven is pending)."
  @spec ready_to_install?(server()) :: boolean()
  def ready_to_install?(server), do: GenServer.call(server, :ready?)

  @doc """
  The boot-time check; call after `Store.boot/2` and before any app code
  runs. `{:error, _}` means the probation state couldn't be made durable:
  run bundled code.
  """
  @spec on_boot(server(), Store.verify_fun()) ::
          {:ok, :clean | :armed | :rolled_back} | {:error, term()}
  def on_boot(server, verify), do: GenServer.call(server, {:on_boot, verify})

  @doc """
  The app reached first idle: disarm the manifest this session booted, and
  from now on `first_idle?/1` is true.
  """
  @spec mark_stable(server()) :: :ok | {:error, term()}
  def mark_stable(server), do: GenServer.call(server, :mark_stable)

  @doc "Whether this VM reached first idle (`mark_stable/1`); survives a restart of the watchdog."
  @spec first_idle?(server()) :: boolean()
  def first_idle?(server), do: GenServer.call(server, :first_idle?)

  @doc "Whether this device rolled back `manifest` (with id `id`) or the same code before."
  @spec rejected?(server(), Store.manifest_id(), Manifest.t()) :: boolean()
  def rejected?(server, id, %Manifest{} = manifest),
    do: GenServer.call(server, {:rejected?, id, manifest})

  @doc "The rollback notice, once: returns it and clears it."
  @spec take_notice(server()) :: notice() | nil
  def take_notice(server), do: GenServer.call(server, :take_notice)

  # ── server ──────────────────────────────────────────────────────────────

  # `booted` is the manifest this session booted under probation.
  @impl true
  def init(opts) do
    idle_key = {__MODULE__, Keyword.get(opts, :name, __MODULE__), :first_idle}

    {:ok,
     %{
       store: Keyword.get(opts, :store, Store),
       app_version: Keyword.get_lazy(opts, :app_version, &Config.app_version/0),
       idle_key: idle_key,
       first_idle: :persistent_term.get(idle_key, false),
       state: nil,
       booted: nil
     }}
  end

  # Neither needs the persisted state.
  @impl true
  def handle_call(:first_idle?, _from, s), do: {:reply, s.first_idle, s}

  def handle_call(:mark_stable, from, %{first_idle: false} = s) do
    :persistent_term.put(s.idle_key, true)
    handle_call(:mark_stable, from, %{s | first_idle: true})
  end

  def handle_call(request, from, %{state: nil} = s) do
    case load(s) do
      {:ok, s} -> handle_call(request, from, s)
      {:error, reason} -> {:reply, unreadable_reply(request, reason), s}
    end
  end

  def handle_call({:install, body, manifest, expected}, _from, s) do
    id = Store.manifest_id(body)

    cond do
      refused?(s, id, manifest) -> {:reply, {:ok, :rejected}, s}
      id == Store.active_id(s.store) -> {:reply, {:ok, :current}, s}
      s.state.armed != nil -> {:reply, {:ok, :deferred}, s}
      true -> transact_install(s, id, body, manifest, expected)
    end
  end

  def handle_call(:ready?, _from, s), do: {:reply, s.state.armed == nil, s}

  def handle_call({:on_boot, verify}, _from, s) do
    {reply, s} = check_boot(s, verify, 2)
    {:reply, reply, s}
  end

  def handle_call(:mark_stable, _from, s) do
    {reply, s} = disarm_if_booted(s)
    {:reply, reply, s}
  end

  def handle_call({:rejected?, id, manifest}, _from, s),
    do: {:reply, refused?(s, id, manifest), s}

  def handle_call(:take_notice, _from, s) do
    case s.state.notice do
      nil ->
        {:reply, nil, s}

      notice ->
        # If clearing can't be persisted the notice may show again next launch.
        {_, s} = write(s, %{s.state | notice: nil})
        {:reply, notice, s}
    end
  end

  # An unreadable record fails closed: no boot of delivered code, no
  # install, everything counts as rejected. Corrupt *content* is recoverable
  # — the rejected list is lost, but whatever is active goes back on
  # probation rather than being trusted.
  defp load(%{state: nil} = s) do
    case read(s.store) do
      {:ok, state} ->
        {:ok, %{s | state: state}}

      {:reset, reason} ->
        Logger.warning(
          "mob_deliver: watchdog state corrupt (#{inspect(reason)}); re-probating the active manifest"
        )

        {:ok, %{s | state: %{@empty | armed: Store.active_id(s.store)}}}

      {:error, reason} = error ->
        Logger.error("mob_deliver: watchdog state unreadable (#{inspect(reason)})")
        error
    end
  end

  defp unreadable_reply(:ready?, _reason), do: false
  defp unreadable_reply({:rejected?, _id, _manifest}, _reason), do: true
  defp unreadable_reply(:take_notice, _reason), do: nil
  defp unreadable_reply(_request, reason), do: {:error, {:watchdog_unreadable, reason}}

  defp refused?(s, id, manifest) do
    id in s.state.rejected or {Manifest.code_id(manifest), s.app_version} in s.state.rejected_code
  end

  # Rejected on another app version only: that version's failure says
  # nothing about this binary.
  defp rejected_elsewhere?(s, manifest) do
    code = Manifest.code_id(manifest)
    Enum.any?(s.state.rejected_code, fn {c, v} -> c == code and v != s.app_version end)
  end

  defp transact_install(s, id, body, manifest, expected) do
    with {:ok, armed} <- write(s, %{s.state | armed: id, boots: 0}) do
      case Store.activate(s.store, body, manifest, expected) do
        :ok ->
          {:reply, {:ok, :installed}, armed}

        {:error, _} = error ->
          # Best effort: a leftover beacon names a non-active manifest and is
          # discarded at the next boot.
          {_, s} = write(armed, %{armed.state | armed: nil, boots: 0})
          {:reply, error, s}
      end
    else
      {{:error, _} = error, s} -> {:reply, error, s}
    end
  end

  defp disarm_if_booted(s) do
    if s.state.armed != nil and s.state.armed == s.booted and s.booted == Store.active_id(s.store) do
      # Proven on this app version: rejections of the same code on other
      # versions no longer apply here.
      {_id, manifest} = Store.active(s.store)
      code = Manifest.code_id(manifest)
      kept = Enum.reject(s.state.rejected_code, fn {c, _v} -> c == code end)

      case write(s, %{s.state | armed: nil, boots: 0, rejected_code: kept}) do
        {:ok, s} ->
          Logger.info("mob_deliver: manifest #{s.booted} reached first idle; disarmed")
          {:ok, s}

        {{:error, _} = error, s} ->
          error_reply(error, s)
      end
    else
      {:ok, s}
    end
  end

  # `budget` bounds rollbacks per boot (there are only two slots).
  defp check_boot(s, verify, budget) do
    {active, manifest} = Store.active(s.store) || {nil, nil}
    state = s.state

    cond do
      active != nil and budget > 0 and refused?(s, active, manifest) ->
        roll_back(s, active, verify, budget)

      active != nil and budget > 0 and state.armed == active and state.boots >= 1 ->
        Logger.warning("mob_deliver: manifest #{active} never reached first idle; rolling back")

        rejected = %{
          state
          | armed: nil,
            boots: 0,
            rejected_code: [{Manifest.code_id(manifest), s.app_version} | state.rejected_code],
            notice: %{rolled_back: active, at: DateTime.utc_now()}
        }

        case write(s, rejected) do
          {:ok, s} -> roll_back(s, active, verify, budget)
          {error, s} -> error_reply(error, s)
        end

      active != nil and state.armed == active ->
        probation_boot(s, active, state.boots + 1)

      active != nil and rejected_elsewhere?(s, manifest) ->
        # A rollback recorded on an older app version never completed, and
        # the app has been updated since: probation on this version.
        Logger.warning(
          "mob_deliver: manifest #{active} was rejected on another app version; " <>
            "booting it on probation on #{inspect(s.app_version)}"
        )

        probation_boot(s, active, 1)

      state.armed != nil ->
        # Stale beacon (activation never happened); clearing is best effort.
        {_, s} = write(s, %{state | armed: nil, boots: 0})
        {{:ok, :clean}, s}

      true ->
        {{:ok, :clean}, s}
    end
  end

  defp probation_boot(s, active, boots) do
    case write(s, %{s.state | armed: active, boots: boots}) do
      {:ok, s} -> {{:ok, :armed}, %{s | booted: active}}
      {error, s} -> error_reply(error, s)
    end
  end

  defp roll_back(s, active, verify, budget) do
    case Store.rollback(s.store, active, verify) do
      {:ok, _} ->
        case check_boot(s, verify, budget - 1) do
          {{:ok, _}, s} -> {{:ok, :rolled_back}, s}
          error -> error
        end

      {:error, reason} ->
        Logger.error("mob_deliver: rollback of #{active} failed (#{inspect(reason)})")
        {{:error, {:rollback_failed, reason}}, s}
    end
  end

  defp error_reply({:error, reason}, s) do
    Logger.error("mob_deliver: watchdog state not persisted (#{inspect(reason)})")
    {{:error, reason}, s}
  end

  # ── disk ────────────────────────────────────────────────────────────────

  defp read(store) do
    case Disk.read_term(path(store)) do
      {:ok, %{armed: armed, boots: boots, rejected: rejected, notice: notice} = state}
      when (is_binary(armed) or is_nil(armed)) and is_integer(boots) and is_list(rejected) and
             (is_map(notice) or is_nil(notice)) ->
        {:ok,
         %{
           armed: armed,
           boots: boots,
           rejected: strings(rejected),
           # Absent in state written by 0.1.0.
           rejected_code: code_rejections(Map.get(state, :rejected_code, [])),
           notice: notice
         }}

      {:error, :missing} ->
        {:ok, @empty}

      {:error, :undecodable} ->
        {:reset, :undecodable}

      {:ok, other} ->
        {:reset, {:unexpected, other}}

      {:error, _} = error ->
        error
    end
  end

  defp strings(list), do: Enum.filter(list, &is_binary/1)

  defp code_rejections(list) when is_list(list) do
    for {code, version} = rejection <- list,
        is_binary(code) and (is_binary(version) or is_nil(version)),
        do: rejection
  end

  defp code_rejections(_), do: []

  # Memory follows disk: on failure the old state stays in effect.
  defp write(s, state) do
    case Disk.atomic_write(path(s.store), :erlang.term_to_binary(state)) do
      :ok -> {:ok, %{s | state: state}}
      {:error, _} = error -> {error, s}
    end
  end

  defp path(store), do: Path.join(Store.root(store), "watchdog")
end
