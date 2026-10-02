# AGENTS.md — orientation for AI agents working on mob_deliver

You're in **mob_deliver**, a Mob plugin: content-addressed BEAM delivery for Mob apps. Two consumers of one primitive — proactive OTA updates (fetch a signed manifest, hot-load module-by-module) AND JIT screen delivery (router cache miss triggers on-demand fetch of one module).

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view and the cross-cutting pre-empt-failure rules. And **read the scope ADR** — [`decisions/2026-09-19-scope-and-wire-format.md`](decisions/2026-09-19-scope-and-wire-format.md) — before you touch anything wire-format-adjacent. It's the load-bearing document for what's in v1 vs future work; everything else defers to it. For the manifest schema, read [`~/code/mob/MOB_PLUGINS.md`](../mob/MOB_PLUGINS.md).

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

* `lib/mob_deliver.ex` — public API, none of it raising while the app isn't running: `fetch_manifest/0`, `check/0` and `check/1` (`details: true` adds `restart_required`, from `restart.ex`: an active-manifest module loaded in this session with different code, by `module_info(:md5)`), `resolve/1`, `on_start/0` (plugin lifecycle), `mark_stable/0`, `take_rollback_notice/0`, `rollback_notice/0` (not consuming), `update_status/0`, `state/0` (check results kept in `status.ex`), `root_screen/2`, `open_store/0`; `on_wake_push/1` is the mob_wake handler; `on_resume/0`/`on_background/0` are the plugin's lifecycle hooks (pause/resume timed checks).
* `lib/mob_deliver/manifest.ex` — wire format v1 manifest: canonical signing payload, Ed25519 verification, typed parse. Signature is checked before any field is read.
* `lib/mob_deliver/client.ex` — `POST /manifest`, `GET /beam/:sha` over Req (retries + body decoding off; TLS options via `:req_options`). `{:error, :not_configured}` (logged) for a nil endpoint/app/channel; anything `Req.request/1` raises or exits with (e.g. Mint's missing-CA-store `RuntimeError`) becomes `{:error, {:transport, _}}`.
* `lib/mob_deliver/store.ex` — content-addressed store: `blobs/<sha>` (re-hashed on every read; a corrupt file is reported, never unlinked — that could delete a concurrent repair) and a `state` file holding the active/previous **signed manifest bodies** (not references), so replacing it is the one atomic slot switch and nothing in it is used unverified. Boot re-verifies, falls back active → previous → bundled, and persists the outcome. The process's in-memory slots are the compare-and-set truth for `activate/4`/`rollback/3`, so `active_id/1` is always a working token even if a persist failed.
* `lib/mob_deliver/bundled.ex` + `build.ex` — MOB-361: a manifest only fits the app build it was installed on. `Bundled` fingerprints the binary's own `.beam` files on the code path (`:beam_lib.md5`, found by file name, no atoms); `Build.base_of/2` is recorded with the slot at install (`Store` keeps `bases` per slot id); `Build.check/4` at boot says `:ok`, `{:adopt, base}` (every bundled module that changed under it, or all for a pre-base manifest, is now identical to the delivered one: still fits, record the new base) or `{:stale, pairs, keys}` (bundled code changed to something else → `Store.retire/2` + `Watchdog.supersede/2` with the outgrown pairs of both slots — only delivered versions known by md5 to differ from the bundled code, never one the build ships; pairs whose blob was missing go to the watchdog's `unresolved` list and `Build.settle_unresolved/2` compares them after prefetch (clear or promote) before `Watchdog.install`, which refuses uncompared ones; the JIT refresh holds the server's manifest to the same rule (`Build.fits/2`) and the resolver never loads a closure pair `Watchdog.outgrown/2` names; `check/0` then answers `:stale_for_build`). Not a rejection.
* `lib/mob_deliver/disk.ex` — tmp → fsync → rename → fsync(dir) writes, durable directory creation (every new dir's parent synced). Post-rename sync failure counts as committed (logged). Never raises.
* `lib/mob_deliver/resolver.ex` + `loader.ex` — JIT `resolve/1`. Pins **one** manifest for the whole call closure (from the beam's imports chunk), fetches everything before loading anything, loads callees first and the target last (a failed callee leaves the target unloaded and retryable), checks the beam defines the named module, and never kills processes to purge old code. A module in neither the active manifest nor the binary (and not a route atom) goes through `refresh.ex` — **only after first idle** (`Watchdog.first_idle?/1`: uninstalled code has no probation record, so it must never run during startup): the server's newest manifest, fetched at most once per `:refresh_interval` (errors cached too), gate re-evaluated after it, used for that closure only if installable and not rejected — never installed (ADR "JIT miss: manifest refresh").
* `lib/mob_deliver/single_flight.ex` — collapses concurrent calls per key into one execution (rule 4). Runners are linked and killed in `terminate/2`, so a restarted registry never overlaps them.
* `lib/mob_deliver/config.ex` — the only reader of `config :mob_deliver`, all at runtime (MOB-357: no `compile_env`; the trust settings — key, app, channel, app_version — are read from the build's `mob_app_config` module itself, never the mutable app env (`Application.put_env/3`), falling back to the env only off-device when that module is absent (on a device, absent = nothing trusted); defence in depth, not a boundary — `decisions/2026-10-02-delivered-code-threat-model.md`; that module `protected.ex` keeps delivered code from replacing, along with `MobDeliver.*`, `Mob.*`, `:mob_nif` and the Elixir/crypto/public_key apps — refused at install, by the JIT refresh and by `Loader.load/3`). Store root defaults to `<MOB_DATA_DIR>/mob_deliver`, resolved without `mkdir_p!` so app start can't crash on the filesystem; native app version read once per VM. On device the config exists only because mob ≥ 0.9.6 loads the `mob_app_config` module mob_dev ships; `missing/0` names what's unset, and boot refuses a malformed key with a message (state untouched).
* `lib/mob_deliver/boot.ex` — plugin `on_start`: if the OTP application isn't running or the config is missing, log and do nothing (stored state untouched). Else store boot → retire the active manifest if the build outgrew it → watchdog check (may roll back; on error → `Store.unpublish/1`, bundled code; after a rollback the outgrown check runs again) → load the delivered modules whose blob is local **and whose delivered callees are all local** (blobs are shared by SHA with refreshed closures, so a local module can have a missing active-version callee), callees first, each with a timeout → blob GC → router hooks → poller. Runs before the host's `on_start`; catches everything, because a raise aborts app boot and a hang blocks it.
* `lib/mob_deliver/hooks.ex` — `Mob.Router.Hooks` integration (mob ≥ 0.9.6): `:before_navigate` → `resolve/1` (fetch JIT screens; past the deadline `{:reset, update_screen}` replaces the whole navigation; pass through route atoms and unknown modules; refuse with a warning when delivery fails); `:after_first_render` (called with the screen whose frame committed) → `mark_stable/0`, except for the update screen (or `nil`): `mark_idle_unproven/1` and `Mob.Router.Hooks.rearm_first_render/0`, so the app's own first frame proves the update whenever it comes.
* `lib/mob_deliver/watchdog.ex` — probation for installs: `install/5` is the only way to activate (arm + activate as one transaction; a manifest with exactly the proven active manifest's modules is adopted without arming), one unproven install at a time, boots counter, disarm only the manifest *this session booted*, durable rejections (authoritative; per app version, the **suspects** — module→SHA pairs the rolled-back manifest introduced relative to its rollback target (`Store.previous/2`), minus those whose blob was on the device before the install (`preexisting`, computed by the installer before prefetch), and that the failed launch loaded (`note_loaded/2`, called by boot and `resolve/1` before loading, durable during probation; unknown → all) — refusing any manifest that ships all of them; plus unconditional 0.1.0 payload ids and b6904ba's `rejected_code` digests, migrated), a manifest rejected only on another app version boots armed, proving it drops those, one-time notice, memory changes only after a durable write. Also `first_idle?/1` (per VM, survives a watchdog restart; set only by a proving frame), `mark_idle_unproven/1` (update-screen frame: nothing proven, launch not counted) and `resume_probation/1` (the gate opened: count the launch again before the root mounts). The ADR's "Client-side rollback" section is the protocol.
* `lib/mob_deliver/installer.ex` + `fetcher.ex` — `check/0`: fetch the signed manifest, record it with the gate, cheap pre-checks (current / below floor / rejected / deferred), note which new module versions are already in the store (`preexisting`), prefetch new versions of modules the device already runs (delivered or bundled — checked with existing atoms only), delivered modules that loaded code *imports* (scan of loaded modules' imports chunks, only when some manifest key's atom exists), plus every delivered module they call, then `Watchdog.install/5`. `Fetcher.ensure_blob/2` is the one-download-per-SHA path shared with `resolve/1`.
* `lib/mob_deliver/poller.ex` — when checks run: at boot, every `:poll_interval` (default 1h, `false` off) **only while foregrounded** (paused by `on_background`, which cancels the timer; an overdue check runs on `on_resume`), deferrals retried with exponential backoff from 5s capped at the interval, and on a mob_wake silent push (`:mob_deliver_check`, registered only if `Mob.Wake` is loaded and `:on_push` isn't `false`). Checks run unlinked + monitored; a restarted poller resumes if boot had started it.
* `lib/mob_deliver/gate.ex` + `update_required_screen.ex` + `gate_navigation.ex` — the forced-update window from the newest verified manifest (installed or not; persisted signed, re-verified at boot, `issued_at` monotonic). App version from `Mob.Device.app_version/0` or `:app_version`; fail-open on unparseable versions, logged once per record/load. Applied via `root_screen/2` (which records the requested root), `resolve/1`, and `GateNavigation`, one supervised process that reconciles navigation with the gate *as it is now* whenever asked (Gate `:on_change` when a recorded manifest moves the app into/out of `:required`; the first-render hook): requests coalesce, a busy router is retried, never out of order. It resets through `GenServer.call(:mob_screen, {:navigate, {:reset, dest, %{}, :reset, :all}})` (contract confirmed with mob) and resumes probation before releasing to the root. The screen uses theme tokens only.
* `priv/mob_plugin.exs` — plugin manifest. No NIFs (pure Elixir). Lifecycle `on_start` (boot), `on_resume`/`on_background` (poller). mob starts the `:mob_deliver` OTP application before `on_start`.
* `decisions/` — ADRs. **Read `2026-09-19-scope-and-wire-format.md` first.** Everything else in the repo defers to it.
* `test/` — manifest verification invariants (tamper/forgery/cross-channel/canonical payload golden vector), client wire behaviour via `Req.Test`, store crash/tamper/CAS cases, resolver closure/ordering/pinning with real compiled BEAMs served by a function plug, watchdog crash-ordering and disk-failure scenarios plus a seeded random launch/install/idle sequence checker (simulated launches = fresh processes over the same store root), installer/poller/gate behaviour, and the update screen via `Mob.ScreenCase`. `test/test_helper.exs` defines `MobDeliver.TestPublisher`, the signing side of the wire.

## Cross-repo work

**mob (framework):** mob_deliver requires mob ≥ 0.9.6, which (1) loads the app config mob_dev ships (`mob_app_config`) and `Application.ensure_all_started/1`s every activated plugin before its `on_start` (without that, the plugin's processes and `config :mob_deliver` don't exist on device), (2) fires `:after_first_render` only after the root screen's first frame is committed, and (3) has the `{:reset, module}` `:before_navigate` verdict the update gate uses. To test against an unreleased mob: `MOB_PATH=../mob mix test` (see `mob_dep/0` in mix.exs); without it the `~> 0.9.6` requirement needs mob 0.9.6 on Hex.

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

1. **Never trust an unsigned manifest.** Every fetch verifies the manifest's Ed25519 signature against the build's `trusted_publish_key` (shipped in the native build's config; delivered code can never replace it or the code that checks it) BEFORE any BEAM is downloaded. A missing / mismatched / expired signature is a hard error, no fallback, no user prompt to "trust anyway."
2. **Never `Code.load_binary` a BEAM whose SHA doesn't match the manifest.** Hash the received bytes on every fetch; discard on mismatch. The manifest's per-module SHA is the trust anchor.
3. **The watchdog beacon MUST be cleared inside first-idle, not from `on_start` return.** `on_start` returning `:ok` doesn't prove the app is stable; it proves the boot chain didn't raise. First-idle means the supervision tree survived initial callbacks + the screen mounted. If we clear the beacon from `on_start`, rollback for a crashy-mid-mount update is defeated.
4. **JIT resolve MUST be idempotent + concurrent-safe.** Two processes both hitting `MobDeliver.resolve(MyApp.SomeScreen)` on the same cache miss must not both fetch. Use `:atomics` + a single-flight registry.
5. **Forced-update gate happens BEFORE navigation, not after.** Once `force_update_after` has elapsed and the client is below `min_app_version`, the app boots into the "please update" screen and refuses to mount user screens. Rendering user screens first and only then gating is a bug — leaks whatever state they touch.
6. **Delivery = protocol, not library.** Anyone can implement the server side. Don't grow `mob_deliver` (the client) to depend on `mob_deliver_server` (the reference server helper). The two are peers on either side of the wire.

## Pre-commit + release

Standard mob plugin flow (same as mob, mob_wake, mob_notify, etc.); `credo --strict` includes ExSlop + jump_credo_checks:

```bash
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test
```

Pre-push gate: `.githooks/pre-push` (format, credo, compile; plus tests when `mix.exs` changed). It's invoked from the beads pre-push shim, so set `git config core.hooksPath .beads/hooks` once per clone — **not** `.githooks`, which would silently disable the beads hooks.

Public on GitHub (`GenericJam/mob_deliver`); CI in `.github/workflows/test.yml`. Published on Hex (`mob_deliver`); the package ships `guides/` and `decisions/` so README links resolve.

Releases: a `mix.exs` version bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish). See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md) for the trigger model; do NOT bump versions without explicit permission.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
