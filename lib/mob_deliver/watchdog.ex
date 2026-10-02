defmodule MobDeliver.Watchdog do
  @moduledoc """
  Probation for installed manifests: one whose first boot never reaches
  first idle is rolled back on the next launch.

  State lives in `<store root>/watchdog` and changes only by durable write
  — the in-memory copy is updated after the write succeeds, never ahead.

    1. **Install** (`install/5`) is one serialized transaction: refuse a
       manifest that is rejected or already active, **defer** while any
       install is still unproven (`armed` set — the active manifest hasn't
       passed a probation boot yet), adopt without arming a manifest whose
       modules are exactly the (proven) active manifest's, otherwise arm
       `armed: X, boots: 0` and activate X against the caller's
       compare-and-set token. A failed activation disarms again; a crash in
       between leaves a beacon for a non-active manifest, discarded by the
       next boot.
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

  A rejection records, for **this app version**, the **suspects**: the
  module → SHA pairs the rolled-back manifest introduced relative to the
  manifest it replaced (all of its modules if it replaced bundled code).
  One of them broke the launch. On that app version any later manifest
  that still ships *every* suspect is refused, whatever else changed, so
  re-publishing, or changing only unrelated modules, doesn't reach devices
  again; changing any suspect (the fix) does. If the rolled-back manifest
  introduced nothing (same modules as the one it replaced, so the crash
  wasn't its code), only that exact manifest is refused.

  On another app version (a store update) the same content gets a fresh
  probation; once it passes there, rejections from other versions that
  would refuse it are dropped. Rejections recorded by 0.1.0 are exact
  manifest ids (`rejected`) and stay unconditional.

  Rejections are authoritative: any boot with a rejected manifest active
  rolls it back (so a crash mid-rollback finishes next time) and it's never
  installed again; if the app was updated in between, it boots on
  probation instead. After a rollback nothing is armed, so repeated crashes
  never ping-pong between slots. Any failure to record or perform a
  rollback returns `{:error, _}` and the boot runs bundled code.

  `first_idle?/1` tells whether this VM has reached first idle (the root
  screen's first frame) — until then, `MobDeliver.resolve/1` runs nothing
  that isn't under probation. `mark_idle_unproven/1` is first idle without
  proof: the first screen was the forced-update screen, so the booted
  update's code didn't run and its next launch is on probation again.
  """

  use GenServer

  require Logger

  alias MobDeliver.{Config, Disk, Manifest, Store}

  @type server :: GenServer.server()
  @type notice :: %{rolled_back: Store.manifest_id(), at: DateTime.t()}

  # `loaded`: delivered modules the booted probation launch loaded, or nil
  # when that isn't known (outside probation, or state from older builds).
  # `preexisting`: module versions of the armed install whose blobs were on
  # the device before it (fetched for an earlier manifest or session).
  # `superseded`: delivered `key => sha` pairs a newer build's bundled code
  # replaced (a manifest is stale for this build; see MobDeliver.Build).
  @empty %{
    armed: nil,
    boots: 0,
    rejected: [],
    rejections: [],
    loaded: nil,
    preexisting: %{},
    superseded: [],
    notice: nil
  }

  @typedoc """
  A rolled-back manifest on one app version: the pairs it introduced
  (`suspects`) and its id (for when it introduced none).
  """
  @type rejection :: %{
          suspects: %{String.t() => Manifest.sha256()},
          app_version: String.t() | nil,
          id: Store.manifest_id()
        }

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
  prefetched blobs for). Options:

    * `:preexisting` — the manifest's new module versions whose blobs were
      already on the device before this install (checked before
      prefetching): if the update is rolled back, they aren't suspects.
    * `:base` — the bundled code it lands on (`MobDeliver.Build.base_of/2`),
      kept with its slot.

  A manifest with exactly the active manifest's modules, while that one is
  proven, is adopted as the active manifest without probation: nothing
  new runs (e.g. a re-publish that only moves the update window). One
  that ships a delivered version a newer build superseded is
  `{:ok, :stale_for_build}`.
  """
  @spec install(server(), binary(), Manifest.t(), Store.manifest_id() | nil, keyword()) ::
          {:ok, :installed | :current | :rejected | :deferred | :stale_for_build}
          | {:error, term()}
  def install(server, body, %Manifest{} = manifest, expected, opts \\ []),
    do: GenServer.call(server, {:install, body, manifest, expected, opts})

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

  @doc """
  A frame of the forced-update screen, before any of the booted update's
  screens ran: nothing is proven. The booted update stays unproven
  (installs keep waiting), its launch isn't counted (a launch that only
  ever shows the update screen and then ends is followed by another
  probation launch, not a rollback), and `first_idle?/1` isn't set.
  `resume_probation/1` counts the launch again once its screens run.
  """
  @spec mark_idle_unproven(server()) :: :ok | {:error, term()}
  def mark_idle_unproven(server), do: GenServer.call(server, :mark_idle_unproven)

  @doc """
  The booted update's screens are about to run in this session after all
  (the gate opened after an update-screen launch): count the launch again,
  so dying before the app's root renders rolls the update back as usual.
  """
  @spec resume_probation(server()) :: :ok | {:error, term()}
  def resume_probation(server), do: GenServer.call(server, :resume_probation)

  @doc """
  Delivered modules (key => SHA) this launch is about to load. Call it
  before loading them: while the booted update is on probation the record
  is written durably, so if the launch dies — even mid-load — the rollback
  suspects only the update's new modules that actually ran. Outside
  probation it does nothing. `{:error, _}` if it couldn't be written: then
  don't load them (fail closed).
  """
  @spec note_loaded(server(), %{String.t() => Manifest.sha256()}) :: :ok | {:error, term()}
  def note_loaded(server, pairs) when is_map(pairs),
    do: GenServer.call(server, {:note_loaded, pairs})

  @doc "Whether this VM reached first idle (`mark_stable/1`); survives a restart of the watchdog."
  @spec first_idle?(server()) :: boolean()
  def first_idle?(server), do: GenServer.call(server, :first_idle?)

  @doc "Whether this device rolled back `manifest` (with id `id`) or the same code before."
  @spec rejected?(server(), Store.manifest_id(), Manifest.t()) :: boolean()
  def rejected?(server, id, %Manifest{} = manifest),
    do: GenServer.call(server, {:rejected?, id, manifest})

  @doc """
  Records delivered `{key, sha}` pairs that this build's bundled code
  superseded (durably; never pruned). Not a rejection: no notice, nothing
  counted against the content's probation.
  """
  @spec supersede(server(), Enumerable.t({String.t(), Manifest.sha256()})) ::
          :ok | {:error, term()}
  def supersede(server, pairs), do: GenServer.call(server, {:supersede, Enum.to_list(pairs)})

  @doc "Whether `manifest` ships a delivered version a newer build superseded (`supersede/2`)."
  @spec superseded?(server(), Manifest.t()) :: boolean()
  def superseded?(server, %Manifest{} = manifest),
    do: GenServer.call(server, {:superseded?, manifest})

  @doc "The rollback notice, once: returns it and clears it."
  @spec take_notice(server()) :: notice() | nil
  def take_notice(server), do: GenServer.call(server, :take_notice)

  @doc "The rollback notice, without clearing it."
  @spec notice(server()) :: notice() | nil
  def notice(server), do: GenServer.call(server, :notice)

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

  def handle_call({:install, body, manifest, expected, opts}, _from, s) do
    id = Store.manifest_id(body)
    base = Keyword.get(opts, :base)

    cond do
      refused?(s, id, manifest) ->
        {:reply, {:ok, :rejected}, s}

      id == Store.active_id(s.store) ->
        {:reply, {:ok, :current}, s}

      stale?(s, manifest) ->
        {:reply, {:ok, :stale_for_build}, s}

      s.state.armed != nil ->
        {:reply, {:ok, :deferred}, s}

      same_code_as_active?(s, manifest) ->
        adopt(s, id, body, manifest, expected, base)

      true ->
        preexisting = Keyword.get(opts, :preexisting, %{})
        transact_install(s, id, body, manifest, expected, preexisting, base)
    end
  end

  def handle_call({:supersede, pairs}, _from, s) do
    known = MapSet.new(s.state.superseded)
    new = pairs |> Enum.uniq() |> Enum.reject(&MapSet.member?(known, &1))

    if new == [] do
      {:reply, :ok, s}
    else
      case write(s, %{s.state | superseded: s.state.superseded ++ new}) do
        {:ok, s} -> {:reply, :ok, s}
        {error, s} -> reply(error_reply(error, s))
      end
    end
  end

  def handle_call({:superseded?, manifest}, _from, s), do: {:reply, stale?(s, manifest), s}

  def handle_call(:ready?, _from, s), do: {:reply, s.state.armed == nil, s}

  def handle_call({:on_boot, verify}, _from, s) do
    {reply, s} = check_boot(s, verify, 2)
    {:reply, reply, s}
  end

  def handle_call(:mark_stable, _from, s) do
    {reply, s} = disarm_if_booted(s)
    {:reply, reply, s}
  end

  def handle_call(:mark_idle_unproven, _from, s) do
    if booted_armed?(s) do
      Logger.info(
        "mob_deliver: manifest #{s.booted} booted into the update screen; " <>
          "it stays on probation for its next launch"
      )

      # If this can't be written the launch still counts, and the next one
      # rolls the update back: fail closed.
      case write(s, %{s.state | boots: 0}) do
        {:ok, s} -> {:reply, :ok, s}
        {error, s} -> reply(error_reply(error, s))
      end
    else
      {:reply, :ok, s}
    end
  end

  def handle_call(:resume_probation, _from, s) do
    if booted_armed?(s) and s.state.boots == 0 do
      case write(s, %{s.state | boots: 1}) do
        {:ok, s} -> {:reply, :ok, s}
        {error, s} -> reply(error_reply(error, s))
      end
    else
      {:reply, :ok, s}
    end
  end

  # Only the booted, armed launch keeps a record; outside probation nothing
  # is written.
  def handle_call({:note_loaded, pairs}, _from, s) do
    loaded = s.state.loaded

    cond do
      not booted_armed?(s) or not is_map(loaded) ->
        {:reply, :ok, s}

      Enum.all?(pairs, fn {key, sha} -> Map.get(loaded, key) == sha end) ->
        {:reply, :ok, s}

      true ->
        case write(s, %{s.state | loaded: Map.merge(loaded, pairs)}) do
          {:ok, s} -> {:reply, :ok, s}
          {error, s} -> reply(error_reply(error, s))
        end
    end
  end

  def handle_call({:rejected?, id, manifest}, _from, s),
    do: {:reply, refused?(s, id, manifest), s}

  def handle_call(:notice, _from, s), do: {:reply, s.state.notice, s}

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
  defp unreadable_reply({:superseded?, _manifest}, _reason), do: true
  defp unreadable_reply(:take_notice, _reason), do: nil
  defp unreadable_reply(:notice, _reason), do: nil
  defp unreadable_reply(_request, reason), do: {:error, {:watchdog_unreadable, reason}}

  defp reply({reply, s}), do: {:reply, reply, s}

  defp booted_armed?(s),
    do:
      s.state.armed != nil and s.state.armed == s.booted and s.booted == Store.active_id(s.store)

  defp refused?(s, id, manifest) do
    id in s.state.rejected or
      Enum.any?(
        s.state.rejections,
        &(&1.app_version == s.app_version and refuses?(&1, id, manifest))
      )
  end

  # Written by an unreleased build (b6904ba) as `rejected_code`: the digest
  # of the whole module map. Still refuses that exact map on its version.
  defp refuses?(%{modules_digest: digest}, _id, manifest),
    do: modules_digest(manifest) == digest

  # A manifest that introduced nothing: its crash wasn't its code, so only
  # that exact manifest is refused (an empty suspect set would match all).
  defp refuses?(%{suspects: suspects, id: rejected_id}, id, _manifest) when suspects == %{},
    do: rejected_id == id

  defp refuses?(%{suspects: suspects}, _id, %Manifest{modules: modules}),
    do: Enum.all?(suspects, fn {key, sha} -> Map.get(modules, key) == sha end)

  # Canonical JSON of the module map, hashed: what b6904ba stored.
  defp modules_digest(%Manifest{modules: modules}) do
    Base.encode16(:crypto.hash(:sha256, Manifest.signing_payload(modules)), case: :lower)
  end

  # Refused only on another app version: that version's failure says
  # nothing about this binary.
  defp rejected_elsewhere?(s, id, manifest) do
    Enum.any?(
      s.state.rejections,
      &(&1.app_version != s.app_version and refuses?(&1, id, manifest))
    )
  end

  # Ships a delivered version that a newer build's bundled code replaced.
  defp stale?(s, %Manifest{modules: modules}),
    do: Enum.any?(s.state.superseded, fn {key, sha} -> Map.get(modules, key) == sha end)

  # The pairs `manifest` introduced relative to what it replaced.
  defp suspects(%Manifest{modules: modules}, replaced) do
    before = if replaced, do: replaced.modules, else: %{}
    for {key, sha} <- modules, Map.get(before, key) != sha, into: %{}, do: {key, sha}
  end

  defp transact_install(s, id, body, manifest, expected, preexisting, base) do
    with {:ok, armed} <- write(s, %{s.state | armed: id, boots: 0, preexisting: preexisting}) do
      case Store.activate(s.store, body, manifest, expected, base) do
        :ok ->
          {:reply, {:ok, :installed}, armed}

        {:error, _} = error ->
          # Best effort: a leftover beacon names a non-active manifest and is
          # discarded at the next boot.
          {_, s} = write(armed, %{armed.state | armed: nil, boots: 0, preexisting: %{}})
          {:reply, error, s}
      end
    else
      {{:error, _} = error, s} -> {:reply, error, s}
    end
  end

  # The active manifest is proven (nothing armed) and this one runs exactly
  # its code: no probation needed.
  defp same_code_as_active?(s, %Manifest{modules: modules}) do
    case Store.active(s.store) do
      {_id, %Manifest{modules: ^modules}} -> true
      _ -> false
    end
  end

  # The previous slot becomes the replaced manifest — same code, proven — so
  # a later update still rolls back onto proven code.
  defp adopt(s, id, body, manifest, expected, base) do
    case Store.activate(s.store, body, manifest, expected, base) do
      :ok ->
        Logger.info(
          "mob_deliver: manifest #{id} has the active manifest's modules; adopted without probation"
        )

        {:reply, {:ok, :installed}, s}

      {:error, _} = error ->
        {:reply, error, s}
    end
  end

  defp disarm_if_booted(s) do
    if booted_armed?(s) do
      # Proven on this app version: rejections from other versions that
      # would refuse it no longer apply here.
      {id, manifest} = Store.active(s.store)
      kept = Enum.reject(s.state.rejections, &refuses?(&1, id, manifest))

      case write(s, %{
             s.state
             | armed: nil,
               boots: 0,
               loaded: nil,
               preexisting: %{},
               rejections: kept
           }) do
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

        # What it replaced is the rollback target (or bundled code). Of
        # what it introduced, only what this update brought to the device
        # and this launch loaded can have broken it (everything introduced
        # if the loads weren't recorded).
        introduced = suspects(manifest, Store.previous(s.store, verify))
        brought = Map.reject(introduced, fn {key, sha} -> state.preexisting[key] == sha end)

        rejection = %{
          suspects: ran(brought, state.loaded),
          app_version: s.app_version,
          id: active
        }

        log_suspects(active, rejection.suspects)

        rejected = %{
          state
          | armed: nil,
            boots: 0,
            loaded: nil,
            preexisting: %{},
            rejections: [rejection | state.rejections],
            notice: %{rolled_back: active, at: DateTime.utc_now()}
        }

        case write(s, rejected) do
          {:ok, s} -> roll_back(s, active, verify, budget)
          {error, s} -> error_reply(error, s)
        end

      active != nil and state.armed == active ->
        probation_boot(s, active, state.boots + 1)

      active != nil and rejected_elsewhere?(s, active, manifest) ->
        # A rollback recorded on another app version never completed, and
        # the app has been updated since: probation on this version.
        Logger.warning(
          "mob_deliver: manifest #{active} was rejected on another app version; " <>
            "booting it on probation on #{inspect(s.app_version)}"
        )

        probation_boot(%{s | state: %{state | preexisting: %{}}}, active, 1)

      state.armed != nil ->
        # Stale beacon (activation never happened); clearing is best effort.
        {_, s} = write(s, %{state | armed: nil, boots: 0, preexisting: %{}})
        {{:ok, :clean}, s}

      true ->
        {{:ok, :clean}, s}
    end
  end

  # A fresh probation launch: nothing delivered loaded yet.
  defp probation_boot(s, active, boots) do
    case write(s, %{s.state | armed: active, boots: boots, loaded: %{}}) do
      {:ok, s} -> {{:ok, :armed}, %{s | booted: active}}
      {error, s} -> error_reply(error, s)
    end
  end

  defp ran(introduced, nil), do: introduced

  defp ran(introduced, loaded),
    do: for({key, sha} <- introduced, Map.get(loaded, key) == sha, into: %{}, do: {key, sha})

  defp log_suspects(active, suspects) when suspects == %{},
    do:
      Logger.warning(
        "mob_deliver: #{active} failed without running any module it introduced; only it is refused"
      )

  defp log_suspects(active, suspects) do
    Logger.warning(
      "mob_deliver: refusing on this app version any manifest that still has all of " <>
        "#{Enum.map_join(suspects, ", ", fn {key, sha} -> "#{key}@#{String.slice(sha, 0, 12)}" end)} " <>
        "(introduced by #{active}); change one of them to publish a fix"
    )
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
           # Absent in state written by 0.1.0; `rejected_code` is b6904ba's
           # format, carried over so a rollback it recorded still completes.
           rejections:
             rejections(Map.get(state, :rejections, [])) ++
               legacy_code_rejections(Map.get(state, :rejected_code, [])),
           # Absent (unknown) in state written before loads were tracked.
           loaded: loaded(Map.get(state, :loaded)),
           # Absent in older state: nothing is known to have been there.
           preexisting: loaded(Map.get(state, :preexisting)) || %{},
           # Absent in state written before builds were tracked.
           superseded: pairs(Map.get(state, :superseded, [])),
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

  defp loaded(loaded) when is_map(loaded) do
    if Enum.all?(loaded, fn {key, sha} -> is_binary(key) and is_binary(sha) end),
      do: loaded,
      else: nil
  end

  defp loaded(_), do: nil

  defp strings(list), do: Enum.filter(list, &is_binary/1)

  defp pairs(list) when is_list(list),
    do: for({key, sha} = pair when is_binary(key) and is_binary(sha) <- list, do: pair)

  defp pairs(_), do: []

  # The state file is untrusted input: malformed entries are dropped.
  defp rejections(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{suspects: suspects, app_version: version, id: id}
      when is_map(suspects) and is_binary(id) and (is_binary(version) or is_nil(version)) ->
        if Enum.all?(suspects, fn {key, sha} -> is_binary(key) and is_binary(sha) end),
          do: [%{suspects: suspects, app_version: version, id: id}],
          else: []

      %{modules_digest: digest, app_version: version}
      when is_binary(digest) and (is_binary(version) or is_nil(version)) ->
        [%{modules_digest: digest, app_version: version}]

      _malformed ->
        []
    end)
  end

  defp rejections(_), do: []

  defp legacy_code_rejections(list) when is_list(list) do
    for {digest, version} <- list,
        is_binary(digest) and (is_binary(version) or is_nil(version)),
        do: %{modules_digest: digest, app_version: version}
  end

  defp legacy_code_rejections(_), do: []

  # Memory follows disk: on failure the old state stays in effect.
  defp write(s, state) do
    case Disk.atomic_write(path(s.store), :erlang.term_to_binary(state)) do
      :ok -> {:ok, %{s | state: state}}
      {:error, _} = error -> {error, s}
    end
  end

  defp path(store), do: Path.join(Store.root(store), "watchdog")
end
