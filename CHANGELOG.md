# Changelog

All notable changes to **mob_deliver** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0-dev] - unreleased

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
  via `:app_version` and `:store_url`.
- Blob cleanup at boot (`MobDeliver.Store.gc/1`): blobs referenced by
  neither the active nor the previous manifest, and temp files from
  interrupted writes, are deleted before update checks start.
- Router integration (`MobDeliver.Hooks`): on mob with `Mob.Router.Hooks`,
  every push/reset runs `resolve/1` first (JIT fetch; redirect to the
  update screen past the deadline, `:update_screen` configurable), and the
  root screen's first paint ends the update's probation. Older mob keeps
  the stability timer and app-side `resolve/1`.

### Not yet
- `mob_deliver_server` companion library.
- mob_new template integration (`mobile/` directory).
