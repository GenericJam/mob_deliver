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

**Manifest signing.** The `signature` field is `"ed25519:" <> base64(sig)` (standard alphabet, padded), where `sig` is an Ed25519 signature over the canonical JSON encoding of every other top-level field — unknown future fields included, so additive changes stay signed. Canonical JSON: object keys sorted by UTF-8 byte order at every depth; no whitespace between tokens; strings escape only `"`, `\`, and U+0000–U+001F (non-ASCII as raw UTF-8, `/` unescaped); integers in plain decimal; v1 defines no floats. `MobDeliver.Manifest.signing_payload/1` is the reference implementation, and its tests pin a literal payload. Verifying key is baked into the app at compile time as `config :mob_deliver, :trusted_publish_key` in the form `"ed25519:" <> base64(raw 32-byte public key)` — note mob_dev's plugin trust fingerprints use the same prefix over a SHA-256 *digest* of the key, which can't verify anything; don't paste one here. A client also rejects a validly signed manifest whose `app`/`channel` differ from what it requested, so one publish key can safely sign several channels. `min_app_version` and `force_update_after` may be omitted (no update floor).

**BEAM verification.** Each `.beam` fetched by SHA is hashed on receipt; a mismatch is a hard error, discard. The manifest's per-module SHA is the trust anchor, and the manifest itself is signed — so BEAMs don't need per-blob signatures.

**No client capability negotiation in v1.** The `POST /manifest` request carries only app identity + channel. The server responds with one manifest for that app + channel. Clients that can't satisfy the manifest's `min_app_version` see the forced-update window (below); clients running content compiled against a NIF version they don't have will fail at load time and the user is told to update.

### Forced-update window

Two fields carry the version discipline:

* `min_app_version` — the lowest native app version this manifest is compatible with. A client below this version SHOULD NOT install the manifest's contents.
* `force_update_after` — after this UTC timestamp, a client below `min_app_version` MUST refuse to run and display a "please update from the store" screen.

Between publishing the manifest and `force_update_after`, users get an in-app "update recommended" banner that links to the store. After the deadline, the app hard-stops until updated. This is the same pattern every mobile OTA system converges on (Instagram, Discord, Slack); users are used to it.

As implemented (`MobDeliver.Gate`):

* The gate follows the **newest verified manifest the device has fetched**, installed or not — a manifest the app is too old for is never installed (`check/0` → `{:ok, :below_min_version}`), but its floor must still gate. It applies the moment it's verified (even if persisting fails), is persisted as the signed body, and is reloaded and re-verified whenever the gate process starts, so it holds offline and across restarts; an older signed manifest (lower `issued_at`) can't replace a newer one to lift the gate by replay.
* The native app version comes from `config :mob_deliver, :app_version` — mob has no runtime accessor for `CFBundleShortVersionString`/`versionName`. Versions compare as dotted integers with missing segments as 0 (`"1.4" == "1.4.0"`). If either side isn't in that form, the gate stays **open** and logs: it's an update prompt, not a security boundary.
* **Before navigation:** with mob's router hooks (`Mob.Router.Hooks`, mob after 0.9.4), mob_deliver's `:before_navigate` hook runs `resolve/1` before every push/reset mounts a screen: past the deadline it redirects to the update screen (`:update_screen`, default `MobDeliver.UpdateRequiredScreen`), so no user screen mounts mid-session either. The root screen is decided before the router exists, so the app still boots through `MobDeliver.root_screen/2`. On older mob the app calls `resolve/1` itself before navigating.
* Banner: `MobDeliver.update_status/0` → `{:recommended, info}` for the app to render; `MobDeliver.open_store/0` opens `:store_url`.

### Client-side rollback

Most BEAM changes are safe to hot-load module-by-module — the OTP runtime handles two-version live-load transparently, and a bad module can just be reloaded to the previous version. The problem case is **updates that touch `on_start`**: if a module needed at boot crashes, the app is bricked from the user's POV until a store update lands (weeks).

`mob_deliver` uses a slot-based watchdog. As implemented (`MobDeliver.Store`, `MobDeliver.Watchdog`):

* Two slots, **active** and **previous**, each holding a signed manifest body, live together in one `state` file. Switching slots is one durable atomic write of that file (the original `active/` ↔ `previous/` directory-rename plan had a window where `active/` didn't exist). Blobs are shared content-addressed files, so slots don't copy BEAMs.
* Every install is guarded — there's no reliable way to know which modules an update's boot path touches, so no `restart_required` distinction. `Watchdog.install/4` is one serialized transaction: arm the beacon for X, then activate X against the caller's compare-and-set token (disarming again if activation fails). A crash in between leaves a beacon for a non-active manifest, discarded next boot. Watchdog state changes in memory only after its durable write succeeds.
* The first boot of X increments the beacon; reaching **first idle** disarms it. With mob's router hooks, first idle is the root screen's first paint (`:after_first_render`); on older mob it's `MobDeliver.mark_stable/0` (call it from the root screen once rendered) or, failing that, `:stable_after` ms (default 5000) after boot. Only the manifest this session *booted* can be vouched for — a manifest installed during a session hasn't booted yet.
* A boot that finds X still armed from a previous boot rolls back: X goes on a durable **rejected** list (never pruned) with a one-time notice, then the store reinstates previous (or bundled code if none). The rejected list is authoritative — any boot with a rejected manifest active rolls it back, so a crash mid-rollback completes next time, and the poller never reinstalls X. Manifests are identified by **content** (`Manifest.content_id/1`, the SHA-256 of the canonical signing payload), so re-serializing the same signed manifest can't dodge rejection or "already active".
* If the boot counter, the rejection, or the rollback can't be made durable, that boot runs **bundled code** (`Store.unpublish/1`): delivered code never runs without a durable probation record.
* After a rollback nothing is armed, so repeated crashes never ping-pong between slots.
* **One unproven install at a time:** an install is deferred (`{:ok, :deferred}`) while anything is armed — the booted manifest still on probation, or a manifest installed this session that hasn't booted yet. Otherwise a second install would displace the beacon and a crash would roll back onto an unproven manifest; this way previous is always a proven manifest or bundled code. Re-installing the active manifest is a no-op that leaves its beacon alone.
* Boot loads the delivered modules whose blobs are local, callees before callers (imports chunk), each bounded by a timeout so a delivered `@on_load` can't hang app boot.
* Delivered modules that are *already loaded* are not hot-swapped mid-session: a running session keeps its code, the new manifest's blobs load at the next boot (before any app code runs), and modules not yet loaded resolve to the new manifest immediately via `resolve/1`. This keeps the rollback guarantee meaningful — everything that runs a new version has been through a probation boot.
* `MobDeliver.take_rollback_notice/0` returns the "your last update failed and was rolled back" notice exactly once.

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
