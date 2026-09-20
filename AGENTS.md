# AGENTS.md — orientation for AI agents working on mob_deliver

You're in **mob_deliver**, a Mob plugin: content-addressed BEAM delivery for Mob apps. Two consumers of one primitive — proactive OTA updates (fetch a signed manifest, hot-load module-by-module) AND JIT screen delivery (router cache miss triggers on-demand fetch of one module).

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view and the cross-cutting pre-empt-failure rules. And **read the scope ADR** — [`decisions/2026-09-19-scope-and-wire-format.md`](decisions/2026-09-19-scope-and-wire-format.md) — before you touch anything wire-format-adjacent. It's the load-bearing document for what's in v1 vs future work.

> **Keep this file current.** When you change the wire format, add a slot-management step, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_deliver is, in one paragraph

An on-device content-addressed BEAM store (SHA-256 → `.beam` blob) plus two triggers that populate it. **Trigger 1 (update poll)**: fetch a signed manifest, diff, prefetch cold modules, hot-load. **Trigger 2 (JIT navigation)**: `Mob.Router` calls `MobDeliver.resolve(module)` on a cache miss, we fetch that one module (plus transitive dep BEAMs), verify, `Code.load_binary/3`, mount. Same signing, same store, same verification under both. The wire is deliberately protocol-not-library — v1 ships a client plugin and an opinionated server helper (`mob_deliver_server`), but any static server hosting `beam/:sha` + a signed `POST /manifest` endpoint works.

## What mob_deliver is NOT

* **Not `mob_wake`.** mob_wake handles the OS-fired wake event; mob_deliver handles what to do WITH the wake (fetch + install). A silent-push-triggered update composes them: mob_wake wakes the app on a `:push` handler, the handler calls `MobDeliver.check/0`.
* **Not `mob_push` or `mob_notify`.** Those handle notifications — user-visible and silent. mob_deliver is orthogonal; runs at boot / on wake / on router demand.
* **Not a native-code updater.** BEAMs only. NIF + BEAM-runtime updates require a store submission. v1's answer to "user is on an old app with an old NIF": `min_app_version` + `force_update_after` in the manifest → forced-update window UX. Cross-plugin NIF capability negotiation is out-of-scope for v1 (see ADR "What v1 doesn't try to solve").
* **Not CodePush.** CodePush ships JS bundles for React Native, one bundle per app, no per-module granularity, no JIT-on-navigation. mob_deliver ships individual `.beam` files, hot-loads them per-module, and adds JIT-on-navigation as a first-class trigger.
* **Not a full LiveView-style renderer.** Mob screens render natively via mob's own renderer; mob_deliver just brings the right screen module onto the device at the right time.

## Anatomy of the plugin

* `lib/mob_deliver.ex` — public API. Currently a placeholder + moduledoc; child issues fill it in.
* `priv/mob_plugin.exs` — plugin manifest. No NIFs (pure Elixir). Lifecycle `on_start` initialises the content-addressed store + arms the watchdog.
* `decisions/` — ADRs. **Read `2026-09-19-scope-and-wire-format.md` first.** Everything else in the repo defers to it.
* `test/` — placeholder scaffold; property-tests for signature verification + store atomicity are the highest-value coverage as the plugin lands.

Not yet present (deferred to implementation issues):
* `lib/mob_deliver/store.ex` — on-device content-addressed store (open ETS table + on-disk directory keyed by SHA).
* `lib/mob_deliver/verify.ex` — Ed25519 manifest signature verification against the app-declared trusted publish key.
* `lib/mob_deliver/watchdog.ex` — slot-based rollback state machine.
* `lib/mob_deliver/router.ex` — `resolve/1` cache-miss fetch for the router.
* `lib/mob_deliver/poller.ex` — schedule/silent-push-triggered manifest checks.
* `lib/mob_deliver/gate.ex` — `min_app_version` + `force_update_after` UX gate.

## Cross-repo work

**mob (framework):** `Mob.Router.push_screen/1` (or wherever screen resolution happens) needs a hook to call `MobDeliver.resolve/1` on cache miss. Minimal — a `defoverridable` or a `dispatch_before_navigate` callback. Landed in mob 0.9.4+ (issue in the epic).

**mob_wake:** the `:push` trigger is the natural home for background update checks. mob_deliver's poller reads `Mob.Wake.register(:mob_deliver_check, :push, {MobDeliver, :on_wake_push, []})` at boot if mob_wake is activated.

**mob_new:** template gets a `mobile/` directory in the generated Phoenix project + a `MyAppWeb.MobileScreen` behaviour. The build tool learns to walk `mobile/` and produce content-addressed BEAMs at store-build time (the `ship: :bundled` set) or leave them for server-side delivery (`ship: :expansion`).

**mob_dev:** the publish tool (`mix mob_deliver.publish`) is the server-side equivalent of `mix mob.deploy` — walk the source tree, compile, hash, sign, upload. Uses mob_dev's existing hot-push code path for the compile step.

## Testing

Elixir suite (target discipline as the child issues land):

```bash
mix test
```

Property tests for the load-bearing invariants:

* Signature verification round-trip (sign a manifest, mutate a byte, expect verify fail).
* Content-addressed store atomicity (concurrent writes to the same SHA; concurrent reads during a slot swap).
* Watchdog state machine (crash-before-idle → next boot swaps slots; two consecutive crashes DO NOT keep swapping in a loop).

Integration tests (device-verified, gated by `@tag :integration`):

* Round-trip: publish a fixture manifest to a Bandit test endpoint; client boot fetches, verifies, hot-loads. Assert the fetched module is callable.
* Rollback: publish an update whose module raises in `on_start`; boot, observe crash, boot again, observe rollback + user-visible notice.

Neither the update-poll nor the JIT-nav path exercises native code — pure BEAM. Suite should be fast + hermetic.

## The pre-empt-failure rules that matter here

1. **Never trust an unsigned manifest.** Every fetch verifies the manifest's Ed25519 signature against the compile-time-embedded `trusted_publish_key` BEFORE any BEAM is downloaded. A missing / mismatched / expired signature is a hard error, no fallback, no user prompt to "trust anyway."
2. **Never `Code.load_binary` a BEAM whose SHA doesn't match the manifest.** Hash the received bytes on every fetch; discard on mismatch. The manifest's per-module SHA is the trust anchor.
3. **The watchdog beacon MUST be cleared inside first-idle, not from `on_start` return.** `on_start` returning `:ok` doesn't prove the app is stable; it proves the boot chain didn't raise. First-idle means the supervision tree survived initial callbacks + the screen mounted. If we clear the beacon from `on_start`, rollback for a crashy-mid-mount update is defeated.
4. **JIT resolve MUST be idempotent + concurrent-safe.** Two processes both hitting `MobDeliver.resolve(MyApp.SomeScreen)` on the same cache miss must not both fetch. Use `:atomics` + a single-flight registry.
5. **Forced-update gate happens BEFORE navigation, not after.** Once `force_update_after` has elapsed and the client is below `min_app_version`, the app boots into the "please update" screen and refuses to mount user screens. Rendering user screens first and only then gating is a bug — leaks whatever state they touch.
6. **Delivery = protocol, not library.** Anyone can implement the server side. Don't grow `mob_deliver` (the client) to depend on `mob_deliver_server` (the reference server helper). The two are peers on either side of the wire.

## Pre-commit + release

Standard mob plugin flow (same as mob_wake / mob_notify / etc.):

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
```

Pre-push hook (`.githooks/pre-push`, `git config core.hooksPath .githooks` once per clone) runs the above on every push.

Not yet published to Hex. Kept git-local per Kevin's `feedback_git_local_during_scaffold` — GH Actions private-repo billing means avoiding push until the publish gate is met.
