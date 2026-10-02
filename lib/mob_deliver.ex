defmodule MobDeliver do
  @moduledoc """
  Content-addressed BEAM delivery for Mob apps — proactive OTA updates *and*
  JIT screen delivery.

  Two triggers, one primitive:

  * **Update poll** — at boot, on a schedule, or on a silent push (via
    `mob_wake`), fetch the current manifest, prefetch cold modules,
    signature-verify each `.beam`, hot-load in place.
  * **JIT navigation** — `Mob.Router` calls `MobDeliver.resolve/1` on a
    cache miss. Fetch the one module (plus its transitive deps), verify,
    load, mount. First-tap latency for uncached screens is one round-trip;
    subsequent visits are local.

  Same signing, same verification, same on-device content-addressed store
  under both. The wire format is deliberately protocol-not-library — the
  server-side companion (`mob_deliver_server`) is one convenient
  implementation, but any static server hosting SHA-addressed BEAMs plus a
  signed manifest works.

  Design + scope + wire format v1: `decisions/2026-09-19-scope-and-wire-format.md`.

  ## Which plugin do I actually want?

  MobDeliver sits alongside the notify/push/wake/background quartet at the
  same layer of the ecosystem — it's the "how does my app change after
  install" plugin.

  | I want to…                                                | Plugin                                              |
  |-----------------------------------------------------------|-----------------------------------------------------|
  | **Deliver new/updated Elixir code** (screens, logic, migrations) to shipped apps without a store update | **`mob_deliver`** (this plugin) |
  | Wake the app on a schedule / silent push to run a handler | [`mob_wake`](https://hexdocs.pm/mob_wake)           |
  | Keep the app alive while backgrounded                     | [`mob_background`](https://hexdocs.pm/mob_background) |
  | Send a push from my server                                | [`mob_push`](https://hexdocs.pm/mob_push)           |
  | Register for pushes / schedule local notifications        | [`mob_notify`](https://hexdocs.pm/mob_notify)       |

  A silent-push-driven update flow uses `mob_wake` to schedule the check
  and `mob_deliver` to actually pull + install; the two compose naturally.

  ## What ships in v1

  * Content-addressed on-device BEAM store.
  * Manifest fetch + Ed25519 signature verification against a trusted key
    baked into the shipped app.
  * Delivered modules load at launch, before any app code runs; screens
    not on the device yet load on first navigation (`:code.load_binary/3`).
  * Slot-based watchdog + rollback for updates that DO touch boot: if a
    fresh install crashes before the app reaches its first idle, next boot
    detects it and swaps back to the last-known-good tree.
  * `MobDeliver.resolve/1` — cache-miss fetch, callable from a router.
  * Forced-update window: manifest carries `min_app_version`; clients below
    the floor get a graceful N-day nag then hard-stop with a
    "please update from the store" screen.
  * Server-side companion library (`mob_deliver_server`, separate) that
    turns a Phoenix project's `mobile/` source tree into a signed
    content-addressed publish.

  ## What v1 explicitly does NOT do

  Recorded as future-work possibilities in the ADR, not implemented:

  * Cross-plugin NIF capability negotiation (the "user has mob_camera 0.1.7
    but manifest ships modules built against 0.1.8" case). v1's answer:
    NIF / BEAM-runtime changes require a store update — force-window'd.
  * Multi-target publish (per-client-version content variants).
  * Percentage / cohort rollouts.
  * Session-affinity latching for mid-session module updates.
  * Poisoned-SHA client cache metadata.
  * Delta-encoded bundles between versions.

  See `decisions/2026-09-19-scope-and-wire-format.md` for the full
  rationale on why these are punted and what wire-format hooks are
  already in place to let each one land as an additive change later.
  """

  require Logger

  alias MobDeliver.{Client, Config}

  @doc """
  Fetches the current manifest for this app + channel and verifies its
  signature against the app's `:trusted_publish_key`.

      config :mob_deliver,
        trusted_publish_key: "ed25519:<base64 raw 32-byte public key>",
        app: "com.example.myapp",
        endpoint: "https://updates.myapp.com",
        channel: :production,
        # optional, merged into the Req request (TLS trust, timeouts, …)
        req_options: []

  Returns `{:error, :no_trusted_publish_key}` without touching the network
  when no key was configured at build time.
  """
  @spec fetch_manifest() :: {:ok, MobDeliver.Manifest.t()} | {:error, Client.error()}
  def fetch_manifest do
    with {:ok, manifest, _body} <- Client.fetch_manifest(Config.client_opts()),
         do: {:ok, manifest}
  end

  @typedoc "What `check/0` did; see its docs."
  @type check_outcome ::
          :current | :installed | :rejected | :deferred | :below_min_version | :stale_for_build

  @doc """
  Checks for an update now (the poller also runs this at boot, every
  `:poll_interval` while the app is in the foreground, and on a silent
  push).

    * `{:ok, :installed}` — a new manifest is active; its new versions of
      modules this session already runs load at the next launch (after
      prefetching them now), modules not yet loaded resolve to it at once.
    * `{:ok, :current}` — nothing new.
    * `{:ok, :rejected}` — the published modules were rolled back on this
      device before (same modules, whatever the `issued_at` or update
      window); they're never reinstalled on this app version.
    * `{:ok, :deferred}` — an installed update hasn't passed its probation
      boot yet; retried after it.
    * `{:ok, :below_min_version}` — this app version is below the
      manifest's `min_app_version`: not installed, but the update gate
      (`update_status/0`) now follows it.
    * `{:ok, :stale_for_build}` — the manifest ships versions of modules
      that this app build has newer bundled code for (it was published
      before this build, or from an older checkout); not installed.
    * `{:error, :not_configured}` — `:endpoint`, `:app` or `:channel` is
      unset on this device (logged).
    * `{:error, reason}` — fetch, verification, or prefetch failed; nothing
      changed. Network and TLS failures are `{:transport, _}`.
    * `{:error, :not_running}` — mob_deliver's processes aren't running
      (host tests, or before mob started the plugin).

  Concurrent calls share one check. The result and its time are kept for
  `state/0`.

  **When an install applies.** A running session keeps the code it has
  loaded, and on mob that's every bundled module, loaded at launch. So a
  new version of a module the app already runs applies at the next launch;
  only modules not loaded yet (e.g. a JIT screen not opened this session)
  use it right away. `check(details: true)` and `state/0` say when that's
  the case (`restart_required`), so the app can offer "Restart to update".
  """
  @spec check() :: {:ok, check_outcome()} | {:error, term()}
  def check, do: check([])

  @doc """
  `check/0` with options. `details: true` returns
  `{:ok, outcome, %{restart_required: boolean}}` on success:
  `restart_required` is true while the active manifest has new versions
  of modules this session already runs, which apply at the next launch
  (see `check/0`). Errors are as for `check/0`.
  """
  @spec check(keyword()) ::
          {:ok, check_outcome()}
          | {:ok, check_outcome(), %{restart_required: boolean()}}
          | {:error, term()}
  def check(opts) do
    result =
      running(fn ->
        MobDeliver.SingleFlight.run(
          MobDeliver.SingleFlight,
          :check,
          &MobDeliver.Installer.check/0
        )
      end)

    if result != {:error, :not_running}, do: MobDeliver.Status.put_check(result)

    case {result, Keyword.get(opts, :details, false)} do
      {{:ok, outcome}, true} -> {:ok, outcome, %{restart_required: restart_required?()}}
      _ -> result
    end
  end

  @doc false
  # mob_wake :push handler registered as :mob_deliver_check (see MobDeliver.Poller).
  @spec on_wake_push(map() | nil) :: :ok | {:error, :retry}
  def on_wake_push(_payload) do
    case check() do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :retry}
    end
  end

  @doc false
  # Plugin lifecycle hooks (priv/mob_plugin.exs): timed checks only run in
  # the foreground. Casts: never raise, never block the lifecycle dispatcher.
  @spec on_resume() :: :ok
  def on_resume, do: MobDeliver.Poller.foreground()

  @doc false
  @spec on_background() :: :ok
  def on_background, do: MobDeliver.Poller.background()

  @doc """
  Makes `module` callable, fetching it on a cache miss (JIT delivery).

    * Already loaded → `:ok` immediately (no store or network access).
    * In the active manifest → fetches its `.beam` unless stored locally,
      checks it against the manifest SHA and that it defines `module`,
      then loads it — together with every delivered module it calls that
      isn't loaded yet, so the whole call closure is present.
    * In neither the active manifest nor the app binary (e.g. published
      after the last install), once the root screen has rendered → asks
      the server for its newest manifest — at most once per
      `:refresh_interval` (default 30s), however many misses — and, if
      that delivers `module` and this app version may run it, loads it and
      its closure from there. The manifest itself isn't installed; that
      stays the update check's job. Before the first frame nothing is
      fetched this way (it has no probation record, so it mustn't be able
      to fail a launch): `{:error, :not_found}`.
    * Otherwise → `Code.ensure_loaded/1` (bundled code), or
      `{:error, :not_found}`.
    * Past the forced-update deadline → `{:error, :update_required}`,
      including when the refreshed manifest is what moved the deadline.

  **It blocks the caller for the whole fetch** — network round-trips, up
  to Req's timeouts when the network is slow or blocked. Don't call it
  inline in a screen callback (the screen freezes until it returns);
  either just navigate (mob's router hook calls this for you; a failure
  leaves the user where they are, logged as a `mob_deliver:` warning), or
  resolve off the screen process to show progress and a message on
  failure:

      def handle_info({:tap, :offers}, socket) do
        screen = self()
        Task.start(fn -> send(screen, {:resolved, MyApp.OffersScreen, MobDeliver.resolve(MyApp.OffersScreen)}) end)
        {:noreply, Mob.Socket.assign(socket, :loading, true)}
      end

      def handle_info({:resolved, dest, :ok}, socket),
        do: {:noreply, socket |> Mob.Socket.assign(:loading, false) |> Mob.Socket.push_screen(dest)}

      def handle_info({:resolved, _dest, {:error, _reason}}, socket),
        do: {:noreply, Mob.Socket.assign(socket, loading: false, error: "Couldn't load that screen. Try again.")}

  Concurrent calls for the same module share one fetch. Never kills
  processes to load: if an old version is still running,
  `{:error, :old_code_in_use}`. `{:error, :not_running}` while
  mob_deliver's processes aren't running.
  """
  @spec resolve(module()) :: :ok | {:error, term()}
  def resolve(module), do: running(fn -> MobDeliver.Resolver.resolve(module) end)

  @doc """
  Plugin lifecycle `on_start` (see `priv/mob_plugin.exs`). Runs before the
  app's own `on_start`: re-verifies the stored manifest, rolls back one
  that never reached first idle, loads the delivered modules already on
  the device, hooks into mob's router (JIT fetch + update gate before
  navigation, probation ends at the root screen's first paint) and starts
  update checks. Never raises; on any failure the app runs its bundled
  code. Without its settings (see `check/0`) or its OTP application
  running it logs why and leaves everything untouched.
  """
  @spec on_start() :: :ok
  def on_start, do: MobDeliver.Boot.run()

  @doc """
  Tells the watchdog the app reached first idle: the supervision tree is
  up and the first screen mounted. mob's router hook calls it at the root
  screen's first paint, so apps don't need to.

  Until then, a freshly installed manifest is on probation: if this boot
  dies before getting here, the next boot rolls the manifest back.
  """
  @spec mark_stable() :: :ok | {:error, term()}
  def mark_stable, do: running(fn -> MobDeliver.Watchdog.mark_stable(MobDeliver.Watchdog) end)

  @doc """
  Returns `%{rolled_back: manifest_id, at: DateTime.t()}` exactly once
  after the watchdog rolled back a failed update, else `nil`. Show the
  user a one-time "your last update failed and was rolled back" notice.
  See `rollback_notice/0` to read it without consuming it.
  """
  @spec take_rollback_notice() :: MobDeliver.Watchdog.notice() | nil
  def take_rollback_notice,
    do: running(fn -> MobDeliver.Watchdog.take_notice(MobDeliver.Watchdog) end, nil)

  @doc """
  The pending rollback notice, without consuming it (`nil` if there is
  none, or once `take_rollback_notice/0` took it) — e.g. for a settings
  screen that shows it until the user dismisses it.
  """
  @spec rollback_notice() :: MobDeliver.Watchdog.notice() | nil
  def rollback_notice,
    do: running(fn -> MobDeliver.Watchdog.notice(MobDeliver.Watchdog) end, nil)

  @doc """
  The forced-update window for this app version right now (see
  `MobDeliver.Gate`): `:ok`, `{:recommended, info}` — show an "update
  available" banner that calls `open_store/0` — or `{:required, info}`.
  Needs `:store_url`; the app's version comes from mob's native accessor
  (`Mob.Device.app_version()`) or `config :mob_deliver, app_version: "1.4.0"`.
  `:ok` while mob_deliver isn't running.
  """
  @spec update_status() :: MobDeliver.Gate.status()
  def update_status, do: running(&MobDeliver.Gate.status/0, :ok)

  @typedoc "See `state/0`."
  @type state :: %{
          running: boolean(),
          active: %{id: String.t(), issued_at: DateTime.t()} | nil,
          last_check: %{result: term(), at: DateTime.t()} | nil,
          update_status: MobDeliver.Gate.status(),
          restart_required: boolean(),
          rollback_notice: MobDeliver.Watchdog.notice() | nil
        }

  @doc """
  Delivered-code state for an "app version" or diagnostics screen. Never
  raises; while mob_deliver isn't running (host tests, early boot) it
  reports `running: false` and empty values.

    * `:active` — the active manifest's id and `issued_at`, or `nil` when
      the app runs its bundled code.
    * `:last_check` — the last `check/0`'s result (by the poller, a push,
      or the app) and when it finished, or `nil` before the first.
    * `:update_status` — as `update_status/0`.
    * `:restart_required` — the active manifest has new versions of
      modules this session already runs; they apply at the next launch
      (see `check/0`).
    * `:rollback_notice` — as `rollback_notice/0` (not consumed).
  """
  @spec state() :: state()
  def state do
    %{
      running: running?(),
      active: running(&active/0, nil),
      last_check: MobDeliver.Status.last_check(),
      update_status: update_status(),
      restart_required: restart_required?(),
      rollback_notice: rollback_notice()
    }
  end

  defp active do
    case MobDeliver.Store.active(MobDeliver.Store) do
      {id, manifest} -> %{id: id, issued_at: manifest.issued_at}
      nil -> nil
    end
  end

  defp running?, do: Process.whereis(MobDeliver.Store) != nil

  defp restart_required?,
    do: running(fn -> MobDeliver.Restart.required?(MobDeliver.Store) end, false)

  # Runs `fun` unless mob_deliver's processes are down (then, or if it
  # raises or exits because they went down meanwhile, `default`).
  defp running(fun, default \\ {:error, :not_running}) do
    if running?(), do: fun.(), else: default
  catch
    :exit, _ -> default
    :error, %ArgumentError{} -> default
  end

  @doc """
  The screen to boot into: `screen`, or `update_screen` (default
  `MobDeliver.UpdateRequiredScreen`) once the app is past
  `force_update_after` and below `min_app_version`. Decide the root with
  it so the gate applies before any user screen mounts:

      def on_start do
        {:ok, _} = Mob.Screen.start_root(MobDeliver.root_screen(MyApp.HomeScreen))
      end

  It remembers `screen`: when a newer manifest lifts the gate mid-session,
  navigation is reset from the update screen to `screen`; when one makes
  the gate required, from whatever is showing to the update screen. A
  launch that boots into the update screen doesn't end an update's
  probation (none of its screens ran).

  Never raises: if the gate can't be read (mob_deliver not started), it
  logs why and returns `screen`.
  """
  @spec root_screen(module(), module()) :: module()
  def root_screen(screen, update_screen \\ MobDeliver.UpdateRequiredScreen) do
    if running?() do
      booted =
        case update_status() do
          {:required, _} -> update_screen
          _ -> screen
        end

      MobDeliver.GateNavigation.put_root(screen, booted, update_screen)
      booted
    else
      Logger.error(
        "mob_deliver: update gate unavailable (mob_deliver isn't running), booting #{inspect(screen)}"
      )

      screen
    end
  end

  @doc "Opens `config :mob_deliver, :store_url` (the app's store page). Never raises."
  @spec open_store() :: :ok | {:error, term()}
  def open_store do
    case MobDeliver.Config.get(:store_url) do
      nil -> {:error, :no_store_url}
      url -> Mob.Device.open_url(url)
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
