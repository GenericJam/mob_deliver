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

### Not yet
- Content-addressed on-device store implementation.
- Manifest fetch + Ed25519 verification.
- `MobDeliver.resolve/1` router-integration API.
- Slot-based watchdog + rollback.
- Forced-update window UX.
- `mob_deliver_server` companion library.
- mob_new template integration (`mobile/` directory).
