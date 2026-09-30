# mob_deliver — scope + wire format v1

- **Date**: 2026-09-19
- **Status**: accepted

## Context

Every mobile OS makes a distinction between:

1. **Code that ships with the app binary** — reviewed by the store, updated only by store submission. Native code (ObjC / Swift / Kotlin / Zig / C++ / Rust NIFs), the OTP runtime (ERTS, stdlib), and whatever Elixir bytecode was compiled into the binary at build time.
2. **Content the app fetches at runtime** — user data, remote assets, and (permissively, for interpreted / bytecode-hosting runtimes) new bytecode to run within the shipped runtime. React Native's CodePush and Expo Updates exploit this loophole for JS; the App Store rules (5.2.2, updated ~2020) explicitly allow it for "code within a runtime shipped with your app."

BEAM bytecode fits category 2 perfectly. Mob apps are BEAMs running on a phone with hot-code-load as a first-class primitive (`Code.load_binary/3`). The dev workflow already exercises this: `mix mob.deploy` pushes changed `.beam` files to a running device and hot-loads them module-by-module. Prod OTA is literally that same primitive with a signature + a fetch trigger.

There is also a second, more novel possibility: since screens are already discrete `Mob.Screen` modules, an app can be structured as a **shell + JIT-fetched screens** — an install-time shell (boot, auth, navigation, plugin infra) plus a fleet of leaf screens fetched the first time the user navigates to them. This is the "your mobile app can be a website" pattern. No other mobile stack ships this as a first-class primitive; mob's per-module hot-load makes it a natural extension of the runtime.

This ADR defines the v1 scope and wire format for that primitive. Given the design space is large and much of it is speculative, we're deliberately narrow on v1 and record the rest as future possibilities.

## Decision

Ship a single plugin, `mob_deliver`, with two consumer patterns backed by one primitive.

### Primitive: content-addressed BEAM store

The on-device store maps a **SHA-256** to a `.beam` blob. Every deliverable `.beam` has a stable content address forever — same module compiled twice against the same source + toolchain produces the same SHA. Content-addressed storage means:

* Deduplication is automatic.
* Cache invalidation is trivial (the SHA changes when the content changes).
* Signature verification is per-blob, not per-manifest — a signed blob stays trusted forever.
* The manifest becomes a tiny document (module name → SHA), cheap to fetch on every check.

### Two consumers, one primitive

| Consumer | Trigger | Fetch shape |
|---|---|---|
| **Update poll** | Boot / schedule / silent push (via `mob_wake`) / user "check for updates" | Fetch full manifest; diff against local; fetch each `beam/:sha` for changed modules; hot-load one-by-one; on `on_start`-touching change, request restart. |
| **JIT navigation** | `Mob.Router.push_screen/1` cache miss | Fetch the one module (via manifest lookup); verify signature; `Code.load_binary/3`; mount. |

Both write to the same content-addressed store. A screen fetched by JIT is now available for the update poll to hash-check next cycle; a proactively-updated screen is a JIT cache hit thereafter.

### Wire format v1

```
POST /manifest
Accept: application/vnd.mob-deliver.v1+json
Body:
  {
    "app": "com.example.myapp",
    "channel": "production"
  }

→ 200 OK
  {
    "manifest_version": 1,
    "app": "com.example.myapp",
    "channel": "production",
    "issued_at": "2026-09-19T22:00:00Z",
    "min_app_version": "1.4.0",
    "force_update_after": "2026-10-19T00:00:00Z",
    "modules": {
      "MyApp.HomeScreen":     "sha256:abc123...",
      "MyApp.SettingsScreen": "sha256:def456...",
      ...
    },
    "signature": "ed25519:..."
  }
```

```
GET /beam/:sha256

→ 200 OK
  Content-Type: application/vnd.mob-deliver.beam
  Content-Length: <n>
  <raw .beam bytes>
```

**Manifest signing.** The `signature` field is a base64-encoded Ed25519 signature over a canonical encoding of the manifest (all fields except `signature` sorted and JSON-encoded). Verifying key is baked into the app at compile time as `config :mob_deliver, :trusted_publish_key`. Same shape as mob's existing plugin-signing pattern.

**BEAM verification.** Each `.beam` fetched by SHA is hashed on receipt; a mismatch is a hard error, discard. The manifest's per-module SHA is the trust anchor, and the manifest itself is signed — so BEAMs don't need per-blob signatures.

**No client capability negotiation in v1.** The `POST /manifest` request carries only app identity + channel. The server responds with one manifest for that app + channel. Clients that can't satisfy the manifest's `min_app_version` see the forced-update window (below); clients running content compiled against a NIF version they don't have will fail at load time and the user is told to update.

### Forced-update window

Two fields carry the version discipline:

* `min_app_version` — the lowest native app version this manifest is compatible with. A client below this version SHOULD NOT install the manifest's contents.
* `force_update_after` — after this UTC timestamp, a client below `min_app_version` MUST refuse to run and display a "please update from the store" screen.

Between publishing the manifest and `force_update_after`, users get an in-app "update recommended" banner that links to the store. After the deadline, the app hard-stops until updated. This is the same pattern every mobile OTA system converges on (Instagram, Discord, Slack); users are used to it.

### Client-side rollback

Most BEAM changes are safe to hot-load module-by-module — the OTP runtime handles two-version live-load transparently, and a bad module can just be reloaded to the previous version. The problem case is **updates that touch `on_start`**: if a module needed at boot crashes, the app is bricked from the user's POV until a store update lands (weeks).

`mob_deliver` uses a slot-based watchdog for these cases:

* Track two BEAM slots on disk: `active/` and `previous/`.
* On install of a `restart_required: true` update:
  * Unpack into `pending/`, verify signatures, atomic-rename `active/` → `previous/` and `pending/` → `active/`.
  * Write a `watchdog.pending` beacon file with the new SHA set.
  * On restart, boot from `active/`.
* After the app reaches its first idle callback, clear `watchdog.pending`.
* If the next boot finds `watchdog.pending` unchanged from before restart, the BEAM must have crashed pre-idle → atomic-swap `active/` ↔ `previous/` and boot the rollback tree.
* Present a one-time "your last update failed and was rolled back" notice on the user's next successful boot.

Bricking impossible; user visibility on rollback preserved.

### Phoenix-native server layout

The companion library (`mob_deliver_server`, separate) plugs into a Phoenix project. Developer conventions:

```
myapp_web/
├── controllers/
├── live/
├── mobile/                            <-- mob_deliver reads from here
│   ├── home_screen.ex                 (use MyAppWeb.MobileScreen, ship: :bundled)
│   ├── settings_screen.ex             (:bundled)
│   ├── experimental_flow_screen.ex    (:expansion)
│   └── ...
```

* `use MyAppWeb.MobileScreen, ship: :bundled` — module gets vendored into the store-shipped app at build time via the mob build tool.
* `ship: :expansion` — module stays server-side, delivered on demand via JIT (or by the update poll if the manifest advertises it).
* `mix phx.server` in dev hot-reloads a `mobile/` change into any connected dev-mode mob app AND updates the local manifest that Phoenix serves. Same file, two consumers.
* `mix mob_deliver.publish` in CI compiles the `mobile/` tree, produces content-addressed BEAMs, signs a manifest, uploads to whatever endpoint is configured (Phoenix static / S3 / GCS / etc.).

## Consequences

### What v1 makes possible

* Ship an Elixir bug fix or new screen to production apps without a store re-submission (subject to the update-window discipline for anything that touches boot).
* Structure an app as a small shell + a growing fleet of expansion screens. First-launch download is tiny; screens land as the user reaches them.
* Same developer experience as writing a LiveView: `mobile/` lives next to `live/`, same tooling, same hot-reload.

### What v1 doesn't try to solve

Recorded so we know we know we chose not to solve them, and so the wire format doesn't paint us into a corner:

* **Cross-plugin NIF capability negotiation.** A module compiled against `mob_camera` 0.1.8 delivered to a client running 0.1.7 will fail at load time. v1's answer: bundle NIF changes into a store update, use `min_app_version` + `force_update_after` to nudge users to update. Future v2 could add:
  * A `caps: {...}` field in the manifest request. Server evaluates and returns a *scoped* manifest containing only what the client can run, plus an `unavailable` map with reasons.
  * Static analysis at publish time to auto-compute per-module `min_native` requirements from `:beam_lib.chunks(..., [:imports])` cross-referenced with the mob plugin ecosystem's NIF-to-plugin table.
  * Capability rings (`:core` / `:media` / `:sensors` / `:ml` / `:ota`) as a compressed developer-facing view of the underlying plugin-set.
* **Multi-target publish.** Compiling `mobile/` against every supported (mob, plugin-set) combination and serving a different SHA per client version. The infrastructure cost is real; sensible only if the "supported client version floor" model turns out to be too painful in practice.
* **Percentage / cohort rollouts.** "Roll out this manifest to 5% of users first" — implementable as a per-request response field, but v1 assumes all clients on a channel get the same manifest.
* **Session affinity for mid-session module upgrades.** v1's model: a running session keeps its currently-loaded modules until the next navigation off the affected screen; new sessions get the new modules. Fine for most cases. A future v2 could add a `hot_swap: true` opt-in per module for authors who've kept state compatible.
* **Poisoned-SHA client cache metadata.** If the server misjudges what a client can run and serves a SHA that fails to load, the client should mark that SHA as poisoned and refuse to retry it until the manifest advances. Cheap to add; not needed until v1 misjudges happen in practice.
* **Delta-encoded bundles between versions.** v1 fetches full BEAMs. Full `.beam` size is measured in KB per module; a few MB for a typical app. Not obviously worth the delta-encoding complexity until data shows otherwise.

Each of these is an **additive** change to the wire format — either a new field the client can request or the server can return, or a new response header. `manifest_version: 1` in every response lets clients recognise new servers and vice versa; new-server + new-client can opt into scoped manifests, old-server + old-client continues to work unchanged.

### Store review defense

Both stores allow OTA of interpreted / bytecode-hosted code within a runtime shipped with the app (App Store 5.2.2, Google Play equivalents). Some reviewers still flag it. Standard review-note text to include with every submission of a mob_deliver-using app:

> "This app downloads signed Erlang bytecode that runs within the BEAM VM shipped with the app binary. No native code is downloaded or executed. Bytecode delivery is scoped to feature screens; the app's core (native, BEAM runtime, and store-reviewed screens) is baked into the binary at review time. Content is served over HTTPS from our first-party servers and cryptographically signed with a key embedded in the reviewed app."

## Related

* `mob_deliver-c67` (beads epic) — the parent for v1 implementation; run `bd list --parent mob_deliver-c67` for the child issues.
* Sibling plugins: `mob_wake` (silent-push wake, complements the "when to check" story), `mob_notify` / `mob_push` (the visible-notification quartet), `mob_background` (continuous-keep-alive; different concern).
* Prior art we're deliberately NOT copying wholesale but do learn from: React Native CodePush (JS bundles, no per-module granularity, no JIT-on-nav), Expo Updates (similar), Android A/B partition updates (slot pattern only, no in-runtime bytecode).
