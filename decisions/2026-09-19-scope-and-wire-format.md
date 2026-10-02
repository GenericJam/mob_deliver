# mob_deliver — scope + wire format v1

- **Date**: 2026-09-19
- **Status**: accepted

## Context

Every mobile OS makes a distinction between:

1. **Code that ships with the app binary** — reviewed by the store, updated only by store submission. Native code (ObjC / Swift / Kotlin / Zig / C++ / Rust NIFs), the OTP runtime (ERTS, stdlib), and whatever Elixir bytecode was compiled into the binary at build time.
2. **Content the app fetches at runtime** — user data, remote assets, and (permissively, for interpreted / bytecode-hosting runtimes) new bytecode to run within the shipped runtime. React Native's CodePush and Expo Updates rely on this for JS: Apple's Developer Program License Agreement §3.3.1(B) permits downloaded interpreted code within limits, and Google Play exempts code running in a VM or interpreter (exact text and caveats — including App Review Guideline 2.5.2 — in [`guides/store_review.md`](../guides/store_review.md)).

BEAM bytecode fits category 2 perfectly. Mob apps are BEAMs running on a phone with hot-code-load as a first-class primitive (`:code.load_binary/3`). The dev workflow already exercises this: `mix mob.deploy` pushes changed `.beam` files to a running device and hot-loads them module-by-module. Prod OTA is literally that same primitive with a signature + a fetch trigger.

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
| **Update poll** | Boot / schedule (foreground only: Android blocks a backgrounded app's network, so the timer pauses in the background and an overdue check runs on return) / silent push (via `mob_wake`) / `MobDeliver.check/0` | Fetch full manifest; prefetch new versions of modules the device already runs (and their delivered callees); install on probation. Loaded modules switch at the next launch — see "Client-side rollback". A check deferred by an unproven install is retried with exponential backoff capped at the poll interval. |
| **JIT navigation** | cache miss on navigation (`Mob.Socket.push_screen/3` → the router's `:before_navigate` hook) | Fetch the one module (via manifest lookup, refreshing the manifest if it's not in the active one — below); verify signature; `:code.load_binary/3`; mount. |

Both write to the same content-addressed store. A screen fetched by JIT is now available for the update poll to hash-check next cycle; a proactively-updated screen is a JIT cache hit thereafter.

#### JIT miss: manifest refresh (2026-09-30)

The active manifest is whatever the last update check installed, so a screen published since then is a miss even though the server has it (found in QA: navigation silently did nothing until the next hourly poll). Decision, as implemented (`MobDeliver.Resolver`, `MobDeliver.Refresh`):

* A miss that can refresh is a module in neither the active manifest nor the app binary (`:code.which/1` is `:non_existing`) and not a registered route atom. Loaded, bundled and route destinations never touch the network.
* **Only after first idle.** Before the root screen's first frame (`Watchdog.first_idle?/1`, set by the `:after_first_render` hook) a miss doesn't refresh: it's `:not_found` (logged). Code from a refreshed manifest has no durable probation record, so if it ran during startup and crashed the VM (an `@on_load`, a NIF call), the next launch would find nothing armed, reject nothing, and the same startup would fetch and crash again — a boot loop the watchdog can't see. After first idle a crash in refreshed code is a crash in a screen the user navigated to, not a failed launch: the next launch boots normally from the active slot. We chose deferring over putting refreshed code under probation because probation is per manifest and slot (arming a manifest nobody installed would need a second beacon, and a failed "refresh probation" couldn't roll anything back); a startup that needs a screen from a newer manifest gets it after the next update check installs that manifest. Before first idle, the active manifest (probation-tracked, installed or booted) is the only delivered code that runs.
* The refresh fetches and verifies the server's current manifest (and records it with the update gate like any verified manifest). It's **rate-limited and single-flight**: at most one fetch per `:refresh_interval` (default 30 s); concurrent misses share the in-flight fetch, and later misses inside the window reuse its result, **errors included**. A burst of taps, a mistyped module or an offline device costs one request per window.
* The update gate is evaluated again after the refresh: a refreshed manifest that puts this app past its deadline makes the miss `{:error, :update_required}` at once (the hook resets to the update screen), not `:not_found`.
* If the refreshed manifest delivers the module, may run on this app version (`min_app_version`), and isn't content this device rolled back, the resolver takes **that screen's call closure** from it (pinned to that one manifest, as for any resolve) and loads it. The refreshed manifest is **not installed**: no slot changes, nothing is armed.
* Otherwise the module is `:not_found`, which the router hook passes to the router (its usual "unknown navigation destination" error). A refresh that fails returns its error, which the hook turns into a refused navigation with a `mob_deliver:` warning.

Why not install on a miss: installing is the update check's job and carries the "one unproven install at a time" rule, so a miss while an install is on probation would have to wait anyway, and a tap would pay for prefetching every changed boot module. Loading only the closure keeps both invariants untouched. **What boots is decided only by the active slot.** Blobs are shared by SHA, so a refreshed closure can store a module H whose SHA is also in the active manifest, next to the refreshed manifest's version of H's callee D but not the active one's. Boot therefore loads an active-manifest module only if every delivered callee it imports is local too (transitively; otherwise it's left for `resolve/1`, which fetches the active closure), so a shared blob can never bring up a half-present closure. Blobs no slot references are removed by the next boot's GC and re-fetched on the next miss until an update check installs that manifest. Refreshed code runs only in that session, after first idle, like any JIT screen; its callees that are already loaded keep their loaded version, as for every JIT load.

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

**Manifest signing.** The `signature` field is `"ed25519:" <> base64(sig)` (standard alphabet, padded), where `sig` is an Ed25519 signature over the canonical JSON encoding of every other top-level field — unknown future fields included, so additive changes stay signed. Canonical JSON: object keys sorted by UTF-8 byte order at every depth; no whitespace between tokens; strings escape only `"`, `\`, and U+0000–U+001F (non-ASCII as raw UTF-8, `/` unescaped); integers in plain decimal; v1 defines no floats. `MobDeliver.Manifest.signing_payload/1` is the reference implementation, and its tests pin a literal payload. Verifying key is part of the app build as `config :mob_deliver, :trusted_publish_key` (see "Where the trusted key lives") in the form `"ed25519:" <> base64(raw 32-byte public key)` — note mob_dev's plugin trust fingerprints use the same prefix over a SHA-256 *digest* of the key, which can't verify anything; don't paste one here. A client also rejects a validly signed manifest whose `app`/`channel` differ from what it requested, so one publish key can safely sign several channels. `min_app_version` and `force_update_after` may be omitted (no update floor).

**Where the trusted key lives (MOB-357, 2026-10-01).** 0.2.1 and earlier read the key with `Application.compile_env`, so it was a literal in `MobDeliver.Config`'s BEAM. Mix doesn't recompile a dependency when the host app's config changes, so every `mix` run after adding or changing `config :mob_deliver` aborted ("different value set … during runtime compared to compile time") until `mix deps.compile mob_deliver --force`. Since mob 0.9.6 the app's `config/*.exs` is evaluated at build time and shipped **inside the native build** as the `mob_app_config` module, which mob loads before any plugin starts; so all of mob_deliver's config, the key included, is now read at runtime, and a malformed or missing key stops the plugin at boot with a message saying what to fix (stored manifests untouched). The settings that decide what is trusted — `trusted_publish_key`, `app`, `channel` and `app_version` (the update gate) — are read from **`mob_app_config` itself**, not from the application environment, which anything running in the app can change with `Application.put_env/3` (a delivered module that was allowed in could otherwise swap the key before the next check and have attacker-signed manifests verify); when the build has that module it is authoritative, even for a key it doesn't set. Without it on a device (mob's NIF answers `:android` or `:ios`) nothing is trusted and the plugin reports itself not configured; only off-device (host tests, dev) do they come from the environment. The other settings stay in the environment because changing them can't make anything untrusted run: `endpoint` and `req_options` only decide where and how manifests are fetched — every manifest is still verified against the build's key, so redirecting them is at worst a denial of updates — the intervals only how often, `root` is read once when the store starts, and `store_url`, `update_screen` and `on_push` are presentation that code running in the session controls anyway. This keeps the trust root in the reviewed, signed binary, because nothing delivered can replace where it comes from or the code that checks it: a manifest that delivers `mob_app_config`, any `MobDeliver.*` or `Mob.*` module (or `:mob_nif`), or a module of the Elixir, `:crypto` or `:public_key` applications is refused at install (`{:error, {:protected_modules, keys}}`), never used by a JIT refresh, and the loader refuses to load such a module from the store at all (`MobDeliver.Protected`). That also closes a gap the compile-time key had: a delivered `MobDeliver.Config` would have carried its own key. This is defence in depth, not an in-session boundary: delivered code runs in the same VM with the same privileges and could load its own `mob_app_config` or patch state directly; what is guaranteed is that nothing a session does persists, because every launch reads the trust settings from the build's own files, which the store can't replace (threat model: `2026-10-02-delivered-code-threat-model.md`). A store update with a new key stops old-key manifests from verifying, as before.

**BEAM verification.** Each `.beam` fetched by SHA is hashed on receipt; a mismatch is a hard error, discard. The manifest's per-module SHA is the trust anchor, and the manifest itself is signed — so BEAMs don't need per-blob signatures.

**No client capability negotiation in v1.** The `POST /manifest` request carries only app identity + channel. The server responds with one manifest for that app + channel. Clients that can't satisfy the manifest's `min_app_version` see the forced-update window (below); clients running content compiled against a NIF version they don't have will fail at load time and the user is told to update.

### Forced-update window

Two fields carry the version discipline:

* `min_app_version` — the lowest native app version this manifest is compatible with. A client below this version SHOULD NOT install the manifest's contents.
* `force_update_after` — after this UTC timestamp, a client below `min_app_version` MUST refuse to run and display a "please update from the store" screen.

Between publishing the manifest and `force_update_after`, users get an in-app "update recommended" banner that links to the store. After the deadline, the app hard-stops until updated. This is the same pattern every mobile OTA system converges on (Instagram, Discord, Slack); users are used to it.

As implemented (`MobDeliver.Gate`):

* The gate follows the **newest verified manifest the device has fetched**, installed or not — a manifest the app is too old for is never installed (`check/0` → `{:ok, :below_min_version}`), but its floor must still gate. It applies the moment it's verified (even if persisting fails), is persisted as the signed body, and is reloaded and re-verified whenever the gate process starts, so it holds offline and across restarts; an older signed manifest (lower `issued_at`) can't replace a newer one to lift the gate by replay.
* The native app version comes from `Mob.Device.app_version/0` (the running binary's `CFBundleShortVersionString`/`versionName`), or `config :mob_deliver, :app_version` if set. Versions compare as dotted integers with missing segments as 0 (`"1.4" == "1.4.0"`). If either side isn't in that form, the gate stays **open**: it's an update prompt, not a security boundary. That's logged as a warning naming the offending value when such a manifest is recorded or reloaded (not per navigation).
* **Before navigation:** mob's `:before_navigate` router hook runs `resolve/1` before every push/reset mounts a screen. Past the deadline it answers `{:reset, update_screen}` (the update screen given to `root_screen/2`, else `:update_screen`, default `MobDeliver.UpdateRequiredScreen`; the verdict is mob ≥ 0.9.6): the whole navigation is replaced by the update screen, so no user screen mounts mid-session and back can't return to one. A plain redirect would have pushed the update screen on top of the user's stack, and back revealed the user screen (found in QA). The root screen is decided before the router exists, so the app still boots through `MobDeliver.root_screen/2`.
* **When the gate changes mid-session** (a newly verified manifest moves this app into or out of `:required`, from `check/0`, the poller, or a JIT refresh), navigation follows at once instead of at the user's next tap (`MobDeliver.GateNavigation`): becoming required resets all navigation to the update screen; opening again resets it from the update screen to the root the app asked `root_screen/2` for. The same reconciliation runs at the root screen's first frame, because a cold boot decides its root from the stored gate before the boot-time check can fetch a lifted manifest (found in QA: the user was held on the update screen until a second cold start). One process does all reconciliation: a change only asks it to *look again*, and each pass reads the gate as it is then, so passes never overlap and an older change can't be applied after a newer one; requests during a pass coalesce into one more. A router too busy to answer (a JIT download in progress) is asked again a second later rather than skipped. The reset goes through the router's normal navigation, so the hook still has the last word.
* Banner: `MobDeliver.update_status/0` → `{:recommended, info}` for the app to render; `MobDeliver.open_store/0` opens `:store_url`.

### Client-side rollback

Most BEAM changes are safe to hot-load module-by-module — the OTP runtime handles two-version live-load transparently, and a bad module can just be reloaded to the previous version. The problem case is **updates that touch `on_start`**: if a module needed at boot crashes, the app is bricked from the user's POV until a store update lands (weeks).

`mob_deliver` uses a slot-based watchdog. As implemented (`MobDeliver.Store`, `MobDeliver.Watchdog`):

* Two slots, **active** and **previous**, each holding a signed manifest body, live together in one `state` file. Switching slots is one durable atomic write of that file (the original `active/` ↔ `previous/` directory-rename plan had a window where `active/` didn't exist). Blobs are shared content-addressed files, so slots don't copy BEAMs.
* Every install is guarded — there's no reliable way to know which modules an update's boot path touches, so no `restart_required` distinction (the one exception: a manifest with exactly the proven active manifest's modules, below). `Watchdog.install/5` is one serialized transaction: arm the beacon for X, then activate X against the caller's compare-and-set token (disarming again if activation fails). A crash in between leaves a beacon for a non-active manifest, discarded next boot. Watchdog state changes in memory only after its durable write succeeds.
* The first boot of X increments the beacon; reaching **first idle** disarms it. First idle is the first committed frame of an app screen (mob's `:after_first_render` router hook, which passes the screen whose frame was committed and can be re-armed, mob ≥ 0.9.6). `MobDeliver.mark_stable/0` stays public for apps that want to vouch explicitly. Only the manifest this session *booted* can be vouched for — a manifest installed during a session hasn't booted yet. **A frame of the update screen proves nothing**, whichever way it got there (booted into by `root_screen/2`, or reset to by a gate change before the root's frame committed): none of X's screens ran. The decision uses the screen that actually rendered, not what `root_screen/2` chose. On such a frame X stays armed, the launch isn't counted (its boot count is reset, so a launch that only ever shows the update screen is followed by another probation launch, not a rollback), and the hook is re-armed so the next committed frame is judged too. If the gate then opens in the same session, the launch is counted again *before* navigation returns to the root (`Watchdog.resume_probation/1`), so a crash mounting or rendering the root rolls X back as usual; the root's committed frame proves X.
* A boot that finds X still armed from a previous boot rolls back: a durable **rejection** is recorded (never pruned for the app version it failed on) with a one-time notice, then the store reinstates previous (or bundled code if none). Rejections are authoritative — any boot with a rejected manifest active rolls it back, so a crash mid-rollback completes next time, and the poller never reinstalls X. Manifests are identified by **content** (`Manifest.content_id/1`, the SHA-256 of the canonical signing payload), so re-serializing the same signed manifest can't dodge "already active".
* **A rejection poisons what X brought and ran, not X's payload** (2026-09-30). Found in QA four times: re-running the publish on unchanged bad source produced a new `issued_at` and so a "new" manifest; a follow-up release that changed only an unrelated screen still shipped the broken module; when the suspects were everything X introduced, editing a screen the failed launch never opened got the broken module through; and when they were everything X introduced that the launch loaded, screens fetched and run in earlier sessions (and eagerly loaded at boot) still diluted the set. Each time devices crashed again. A rejection records, for the device's native app version, X's **suspects**: the module → SHA pairs X introduced relative to the manifest it replaced (the rollback target; every pair if it replaced bundled code), **minus those whose blob was already on the device before X was installed** (noted before prefetching; that code arrived with an earlier manifest or session, not with X), **limited to those the failed launch loaded**. Only code that X brought and that ran can have broken the launch. On that app version any later manifest that still ships **every** suspect is refused — at install, in `check/0`'s pre-check, at boot, and for JIT refreshes — whatever else changed and whatever its `issued_at` or update window. Changing any suspect (the fix) lets a manifest through: it gets its own probation, and if it fails too, its own suspects are recorded.
  * *What the launch loaded* is recorded with the watchdog **before** each load — boot's eager loads as one entry, each JIT `resolve/1` closure as it's about to load — and written durably while the booted manifest is on probation (outside probation nothing is written), so a launch that dies at any point, even inside an `@on_load`, has its loads on disk. A load that can't be recorded doesn't happen (boot runs bundled code; the resolve fails). If a failed launch's loads aren't known (state written before loads were tracked), the suspects are everything X introduced.
  * Why "all of the suspects" and not "any": the launch may have run several of X's new modules, and only one need be broken. Refusing any manifest with *any* suspect would block every later release that keeps a good change from X; refusing only the whole set blocks exactly the releases that re-ship what X ran, which is what re-publishing and unrelated-change releases do. The cost: a release that keeps the broken module and changes another of the suspects isn't refused and fails its own probation (bounded, and recorded with a smaller suspect set).
  * If the failed launch ran nothing X brought (X introduced nothing new to the device, or the launch died — an OS kill, say — before loading any), the crash can't be pinned on X's code: only that exact manifest is refused, so the proven manifest it's rolled back to isn't refused with it and a re-publish gets another probation. The trade-off of the pre-existing exclusion: if the culprit's blob was on the device before X (say fetched by a JIT refresh in the installing session), it isn't a suspect, and a re-publish of the same broken module costs devices another probation launch. In practice blobs no slot references are removed at every boot, so "pre-existing" means referenced by the active or previous manifest, or fetched in the installing session.
  * `min_app_version`, `force_update_after` and `issued_at` never matter: they decide whether and when the update gate shows, not what code runs.
  * The **native app version** scopes it: delivered BEAMs run against the binary's bundled modules and NIFs, so the same modules can behave differently after a store update. After a store update the same content — even the unchanged signed manifest — gets a fresh probation launch. Once it passes probation on the new version, rejections from other versions that would refuse it are dropped (they'd otherwise re-arm it on every boot, see next point).
  * If a rejection was recorded but the rollback's slot switch didn't happen (a crash in between) and the app is updated before the next launch, the manifest is still active but no longer refused on the new version. It then boots **armed** (a probation launch), never as proven code.
  * Migration: rejections recorded by 0.1.0 are exact manifest ids (the rejected body is gone after the rollback, so no suspects can be derived). They stay unconditional: the exact manifest is refused on every app version; its modules re-published get one more probation launch on those devices, and are rejected by suspects if they fail again.
  * Development builds between 0.1.0 and this rule (never released) stored `rejected_code`: a digest of the whole module map per app version. It's read as a rejection of exactly that module map on that version, and kept, so a rollback those builds recorded but didn't finish still completes.
* **Any death before first idle rejects.** A probation launch killed by the OS, swiped away by the user, or failing in bundled code or a native library looks exactly like a crash in delivered code: the beacon is still armed at the next boot. We don't try to tell them apart. There's no reliable signal on device (an OS kill leaves no trace in the BEAM, and bundled-code failures can be caused by delivered code they call), and guessing wrong in the lenient direction re-opens the bricking this protects against. The window is short (launch to the root screen's first frame). The cost of a false rejection is bounded: the operator republishes changed content, or the next store update gives it a fresh probation. The operator manual documents both.
* If the boot counter, the rejection, or the rollback can't be made durable, that boot runs **bundled code** (`Store.unpublish/1`): delivered code never runs without a durable probation record.
* After a rollback nothing is armed, so repeated crashes never ping-pong between slots.
* **One unproven install at a time:** an install is deferred (`{:ok, :deferred}`) while anything is armed — the booted manifest still on probation, or a manifest installed this session that hasn't booted yet. Otherwise a second install would displace the beacon and a crash would roll back onto an unproven manifest; this way previous is always a proven manifest or bundled code. Re-installing the active manifest is a no-op that leaves its beacon alone.
* **Same code, no probation** (2026-09-30): a manifest whose module map equals the active manifest's, while that one is proven (nothing armed), is adopted directly: it becomes active and the replaced manifest — same code, proven — becomes previous, so a later update still rolls back onto proven code. Nothing new runs, so there's nothing to prove; before this, re-publishing only to set or lift the update window cost a probation launch and deferred every check until it. (The gate itself already followed the newest verified manifest at once.) While the active manifest is still on probation, such a manifest waits like any install.
* Boot loads the delivered modules whose blobs are local and whose delivered callees are local too (transitively), callees before callers (imports chunk), each bounded by a timeout so a delivered `@on_load` can't hang app boot. An install prefetches what that boot will load: new versions of modules on the device, delivered modules that code loaded in the installing session *calls* (e.g. a bundled screen calling a delivered helper, or a delivered module loaded from the store calling a newly delivered helper; found from the imports chunks of the loaded modules' files, read as bytes because store blobs have no `.beam` suffix), and their delivered callees — so the probation launch doesn't download them while its first screen mounts. A module that's only *named* (a `push_screen` destination) stays JIT.
* Delivered modules that are *already loaded* are not hot-swapped mid-session: a running session keeps its code, the new manifest's blobs load at the next boot (before any app code runs), and modules not yet loaded resolve to the new manifest immediately via `resolve/1`. This keeps the rollback guarantee meaningful — everything that runs a new version has been through a probation boot.
* `MobDeliver.take_rollback_notice/0` returns the "your last update failed and was rolled back" notice exactly once.

Bricking impossible; user visibility on rollback preserved.

### Builds change under manifests (MOB-361, 2026-10-01)

A delivered manifest overrides bundled modules, so it is only right for the app build it was installed on. Found on muster_app's phones: publish A, install it, then `mix mob.deploy --native` a newer build without publishing — every launch still ran A's older screens over the newer bundled ones (a BEAM-push deploy did the same). As implemented (`MobDeliver.Bundled`, `MobDeliver.Build`):

* **Base.** At install the manifest's **base** is recorded with its store slot: for every module it delivers that the app binary also has, the bundled `.beam`'s `:beam_lib.md5` (`key => md5`). The bundled file is found on the code path by name (the store isn't on the code path, so this finds the bundled file even while a delivered version is loaded) and read, so no atoms are created for manifest keys. `beam_lib`'s MD5 covers only the code-bearing chunks, so stripping or signing a build doesn't change it; any code change does. Files on the code path are what mob loads app code from (a flat `-pa` directory on Android, the app bundle on iOS), and a BEAM push replaces those files.
* **At boot,** before the watchdog runs and again after a rollback, the active manifest's base is compared with the bundled code now. A bundled module whose MD5 differs from its base (or that is bundled now and wasn't then) changed under the manifest; it is then compared with the **delivered** version. If every changed one is now identical to what the manifest delivers — a build that ships the delivered code (an OTA fix folded into the next store build) — the manifest still fits: the current bundled code becomes its base and nothing is recorded. Otherwise the build's code is newer than what the manifest was built against: the manifest is **stale for this build**. It is retired: both slots are cleared, the app runs its bundled code, and the next blob GC removes the old blobs. A module bundled at install but not now isn't a mismatch: the delivered version fills a gap rather than overriding newer code.
* **Not a failure.** Retiring happens before the watchdog's boot check, so the manifest's probation beacon is simply cleared: no rejection, no suspects, no rollback notice. A cable deploy kills the running app, and that death isn't counted either.
* **Remembered.** The delivered `key => sha` pairs the build outgrew are recorded durably (`Watchdog.supersede/2`) — only versions known to differ from the new bundled code (compared by MD5), so a version the build itself ships is never refused. Because retiring clears **both** slots, the previous manifest is checked the same way first and its outgrown versions are recorded too (it usually delivers the same module at an older version); a previous manifest that still fits the build records nothing and may be installed again. Any manifest that still ships a recorded pair is `{:ok, :stale_for_build}` from `check/0`, at the install transaction and for any later fetch: the same manifest from the server, a re-publish of it with a new `issued_at`, or a publish from an older checkout that still has that version. A publish made from the new build's source either has new SHAs for those modules or ships exactly the bundled code; both install normally, with the new build as their base. A delivered version whose blob isn't on the device (lost or corrupt) can't be compared at that boot: its manifest is still retired and the pair is recorded as **unresolved**. An install that includes an unresolved pair compares it after prefetch, once the blob is back: identical to the current bundled module (or that module no longer bundled), the pair is cleared and the install proceeds; otherwise it's promoted to superseded and the install is `{:ok, :stale_for_build}`. The install transaction itself refuses any manifest with an uncompared unresolved pair, so the old code can't slip in over the newer binary and a version this build ships is never refused for good.
* **Manifests installed before bases existed** (mob_deliver ≤ 0.2.1) have no base: every module they share with the binary counts as changed and is compared with the delivered version as above — identical everywhere, and the current bundled code is adopted as the base; any difference, and there is no way to tell which is newer, so the manifest is retired as stale. Upgrading mob_deliver needs a new native build anyway, which is exactly the case this protects.
* **Why per module and not the whole build or the app version.** Fingerprinting the whole bundled set (or using the native version/build number) would retire every manifest at every build, including manifests that only add JIT screens and override nothing; a store update would then strand all delivered content until a new publish. Comparing exactly the modules a manifest overrides catches every case where delivered code would replace newer bundled code and nothing else. Delivered-only modules that call changed bundled code aren't covered: their compatibility with the binary is what `min_app_version` and the update window are for.
* **Takes effect at the next launch.** Detection runs at boot. A BEAM push already replaces the running code in the session; a native deploy restarts the app.

### Updates and relaunches (MOB-355, 2026-10-01)

On mob every bundled module is loaded at launch, so "modules this session already runs switch at the next launch" covers nearly the whole app: an install made by the boot-time check applies only at the following launch, and a publish made while the app was closed needs two relaunches (one to install, one to run). Found integrating muster_app.

**Decision: an install applies at the next launch; we report when one is pending instead of changing when code applies.** `check(details: true)` returns `{:ok, outcome, %{restart_required: boolean}}` (`check/0` keeps its shape) and `state/0` has `restart_required`: true while the active manifest delivers a module this session runs with different code (bundled, or another manifest's version; compared by `module_info(:md5)` against the delivered blob, so a re-publish of identical code doesn't ask for a restart). Modules not loaded yet (a JIT screen not opened this session) already take the new version on first use. Two alternatives were rejected:

* **Hot-swapping loaded modules at install.** It would run code mid-session that never had a probation launch, mixed with callers and state from the old version. A crash there is outside any probation record, so nothing would roll it back or refuse it; the guarantee "everything that runs a new version has been through a probation boot" (Client-side rollback) would no longer hold. Opt-in per-module hot swap stays future work ("Session affinity").
* **Waiting for the boot check before the app starts** (a bounded wait so one relaunch suffices). Boot never touches the network: on a slow or unreachable server every launch would pay the wait, for an update that is rare. The cost of the current rule is one extra relaunch only when the publish happened while the app was closed: checks also run every `:poll_interval` in the foreground, on resume when one is due, and on a silent push, so an app in use usually installs during a session and applies at its next launch. While an install is still on probation, further checks are `:deferred` until that install's launch has proven it.

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
* **Poisoned-SHA client cache metadata.** If the server misjudges what a client can run and serves a SHA that fails to load, the client should mark that SHA as poisoned and refuse to retry it until the manifest advances. Cheap to add; not needed until v1 misjudges happen in practice. (Crashes during a probation launch are already covered by the suspect sets under "Client-side rollback"; this item is about load failures and JIT screens outside probation.)
* **Delta-encoded bundles between versions.** v1 fetches full BEAMs. Full `.beam` size is measured in KB per module; a few MB for a typical app. Not obviously worth the delta-encoding complexity until data shows otherwise.

Each of these is an **additive** change to the wire format — either a new field the client can request or the server can return, or a new response header. `manifest_version: 1` in every response lets clients recognise new servers and vice versa; new-server + new-client can opt into scoped manifests, old-server + old-client continues to work unchanged.

### Store review defense

Downloaded interpreted code is allowed on iOS within the limits of the Apple Developer Program License Agreement §3.3.1(B), while App Review Guideline 2.5.2 is what reviewers cite against code that "introduces or changes features" (an earlier draft of this ADR cited 5.2.2, which is about intellectual property). Google Play's Device and Network Abuse policy exempts code running in a VM or interpreter with only indirect access to platform APIs. The quoted rules, the analysis, and the current reviewer-note text are in [`guides/store_review.md`](../guides/store_review.md); the original draft of the note was:

> "This app downloads signed Erlang bytecode that runs within the BEAM VM shipped with the app binary. No native code is downloaded or executed. Bytecode delivery is scoped to feature screens; the app's core (native, BEAM runtime, and store-reviewed screens) is baked into the binary at review time. Content is served over HTTPS from our first-party servers and cryptographically signed with a key embedded in the reviewed app."

## Related

* `mob_deliver-c67` (beads epic) — the parent for v1 implementation; run `bd list --parent mob_deliver-c67` for the child issues.
* Sibling plugins: `mob_wake` (silent-push wake, complements the "when to check" story), `mob_notify` / `mob_push` (the visible-notification quartet), `mob_background` (continuous-keep-alive; different concern).
* Prior art we're deliberately NOT copying wholesale but do learn from: React Native CodePush (JS bundles, no per-module granularity, no JIT-on-nav), Expo Updates (similar), Android A/B partition updates (slot pattern only, no in-runtime bytecode).
