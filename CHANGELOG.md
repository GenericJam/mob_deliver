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

### Not yet
- Slot-based watchdog + rollback.
- Forced-update window UX.
- `mob_deliver_server` companion library.
- mob_new template integration (`mobile/` directory).
