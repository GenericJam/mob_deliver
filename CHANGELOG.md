# Changelog

All notable changes to **mob_deliver** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Removed
- The fallbacks for mob without router hooks: the `:stable_after` timer
  and config key (first idle is always the root screen's first frame) and
  the dynamic hook registration.

### Changed
- **Requires mob ~> 0.9.6** (and its mob_dev), which ships `config/*.exs`
  to the device and starts plugin OTP applications before their
  `on_start`. Without them the plugin failed its boot and
  `root_screen/2` crashed the app's `on_start`. On older mob the plugin now
  logs why and the app runs its bundled code.
- A rolled-back update poisons **what it introduced**, not its signed
  payload: the device records, for its native app version, the module →
  SHA pairs the update introduced relative to the release it replaced, and
  refuses (`{:ok, :rejected}`) any later manifest that still ships all of
  them, whatever its `issued_at`, update window or other changes. So
  re-publishing the same source, or a release that changes only an
  unrelated screen, no longer crashes devices again; changing the broken
  module gets through. After a store update of the app the same content,
  even the unchanged manifest, gets a fresh probation, and a manifest
  whose rollback didn't finish before the store update boots on probation.
  Rejections recorded by 0.1.0 keep refusing their exact manifest on every
  version; the same modules re-published get one more probation launch
  there.
- A launch that boots into the forced-update screen no longer ends the
  booted update's probation (none of its screens ran) and doesn't count as
  a failed launch: the update stays on probation until the app's real root
  renders.
- Installs also prefetch the delivered modules that code loaded on the
  device calls (e.g. a bundled screen calling a delivered helper), so the
  probation launch doesn't download them while its first screen mounts.
- Timed update checks run only while the app is in the foreground
  (Android blocks a backgrounded app's network). The plugin's new
  `on_background`/`on_resume` lifecycle hooks pause them (cancelling the
  timer) and run an overdue check on return.
- A check deferred by an unproven install is retried with exponential
  backoff (5s, doubling, capped at `:poll_interval`) instead of every ~6s.
- Boot loads a delivered module only if every delivered module it calls
  is on the device too; otherwise both load on first use.
- Past the forced-update deadline, navigation **replaces the whole stack**
  with the update screen (`{:reset, screen}` hook verdict, mob 0.9.6), so
  back no longer returns to a user screen.
- A gate change found mid-session applies at once: a newly required gate
  switches to the update screen without waiting for the next navigation,
  and a lifted gate returns an app showing the update screen to the root
  it asked `root_screen/2` for, also right after a cold boot that started
  on the update screen.
- `MobDeliver.UpdateRequiredScreen` uses theme colour tokens (readable in
  dark and light themes) and, without `:store_url`, tells users to update
  from their store instead of showing no action at all.
- Update-check failures are logged at warning level.
- An unparseable `min_app_version` or app version is logged once when the
  manifest is recorded or reloaded, naming the offending side, instead of
  on every navigation.

### Added
- JIT miss refresh: once the first screen has rendered, navigating to (or
  `resolve/1` of) a module that is in neither the active manifest nor the
  binary asks the server for its newest manifest (single-flight, at most
  once per `:refresh_interval`, default 30s, errors included) and loads
  that screen's modules from it without installing it. Screens published
  after the device's last update no longer fail until the next poll.
  Unknown modules still reach the router's normal error; a refreshed
  manifest that puts the app past its deadline resets to the update
  screen. Before the first frame nothing uninstalled runs.
- `{:error, :not_configured}` from `check/0` (logged, naming the missing
  keys) when `:endpoint`, `:app` or `:channel` is unset.
- The Hex package includes `guides/` and `decisions/`, so README links work.

### Fixed
- `Req.request/1` raising (e.g. Mint's "default CA trust store not
  available" on Android without CA certs) is `{:error, {:transport, _}}`,
  not `{:crashed, _}`. README and operator manual show the exact
  `req_options` for Android TLS.
- `root_screen/2` never raises: if the gate can't be read it logs and
  returns the requested screen.
- Log lines: an install no longer claims everything "takes effect at the
  next launch", a rollback says whether it boots the previous manifest or
  bundled code, and a stored blob that can't be read at boot is logged.
- A navigation refused because its screen couldn't be delivered logs a
  `mob_deliver:` warning; a module missing from the last refreshed
  manifest logs how old that manifest is and when the next refresh is
  allowed.
- A rollback of an update whose modules match the release it replaced no
  longer takes that (proven) release down with it.

### Docs
- `resolve/1` blocks its caller for the whole fetch: documented, with a
  pattern for resolving off the screen process and showing a failure.
- Operator manual: config is evaluated on the build machine; Android TLS;
  background network limits and the exact silent-push shape (data-only,
  high-priority FCM via `mob_push`); any death before first idle rejects
  the content; fixing a rolled-back release means changing the broken
  module; `@compile {:no_warn_undefined, Mod}` for bundled code calling a
  delivered module (also in the README).
- ADR: the JIT-miss refresh design, suspect-set rejection, why deaths
  before first idle aren't told apart, gate changes mid-session, and
  `Mob.Device.app_version/0`.

## [0.1.0] - 2026-09-30

### Added
- Scaffold + scope ADR ([`decisions/2026-09-19-scope-and-wire-format.md`](decisions/2026-09-19-scope-and-wire-format.md))
  covering v1's in-scope set, out-of-scope future-work, wire format,
  slot-based rollback, forced-update-window UX, and the Phoenix-native
  server directory layout.
- `MobDeliver` moduledoc — surface preview.
- `priv/mob_plugin.exs` — plugin manifest (no NIFs; pure Elixir plugin).
- `MobDeliver.fetch_manifest/0` — `POST /manifest` against the configured
  endpoint, verified against the compile-time `:trusted_publish_key`
  (`MobDeliver.Client`, `MobDeliver.Manifest`). Hard-fails on a missing,
  malformed, or mismatched signature, and on a signed manifest for a
  different app or channel. The canonical signing payload is specified
  in the ADR.
- `MobDeliver.Store` — on-device content-addressed store: SHA-verified
  blobs, signed manifest bodies re-verified at boot (active → previous →
  bundled fallback), slots switched by one atomic, durable state-file
  write with compare-and-set. `MobDeliver.SingleFlight` collapses
  concurrent work per key.
- `MobDeliver.resolve/1` — JIT delivery of a module and the delivered
  modules it calls, from one pinned manifest, callees loaded before the
  target; single-flight per module and per blob.
- Slot watchdog + rollback (`MobDeliver.on_start/0`, `mark_stable/0`,
  `take_rollback_notice/0`): every install boots on probation; a boot
  that dies before first idle is rolled back on the next launch, the
  manifest is rejected for good, and the user gets a one-time notice.
  Delivered modules on the device load at boot before app code.
- `MobDeliver.check/0` and the poller: checks at boot, every
  `:poll_interval` (default 1h), and on a mob_wake silent push
  (`:mob_deliver_check`, `:on_push`). Prefetches new versions of modules
  the device already runs, then installs through the watchdog; one
  unproven install at a time. `resolve/1` waits for one check when
  nothing is installed yet and no bundled version exists.
- Forced-update window (`MobDeliver.update_status/0`, `root_screen/2`,
  `open_store/0`, `MobDeliver.UpdateRequiredScreen`): below
  `min_app_version` the app gets `{:recommended, _}` until
  `force_update_after`, then boots into the update screen and `resolve/1`
  refuses. Follows the newest verified manifest (replay-safe), configured
  via `:store_url` and the app's version — `:app_version` config, or
  `Mob.Device.app_version()` when mob has it.
- Blob cleanup at boot (`MobDeliver.Store.gc/1`): blobs referenced by
  neither the active nor the previous manifest, and temp files from
  interrupted writes, are deleted before update checks start.
- Router integration (`MobDeliver.Hooks`): on mob with `Mob.Router.Hooks`,
  every push/reset runs `resolve/1` first (JIT fetch; redirect to the
  update screen past the deadline, `:update_screen` configurable), and the
  root screen's first paint ends the update's probation. Older mob keeps
  the stability timer and app-side `resolve/1`.
- Guides: operator manual and store review.

### Related
- [`mob_deliver_server`](https://github.com/GenericJam/mob_deliver_server)
  0.1.0: reference publisher + Plug server.
- `mix mob.new --deliver` (mob_new): generates an app wired for
  mob_deliver with a `mobile/` expansion screen.
