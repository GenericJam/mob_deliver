# Nothing older than the newest verified manifest is used (replay floor)

- Date: 2026-10-15
- Status: accepted; amended 2026-11-14 (durability, per-channel records;
  see "Amendment" below)
- Issue: MOB-382

## Context

A signed manifest never expires: every publish, and every blob it names,
verifies forever. Before this change `MobDeliver.Installer` installed any
validly signed manifest that wasn't the active one, rolled back, outgrown
by the build, or protected. It never compared `issued_at`. The update gate
(`MobDeliver.Gate`) already kept the newest verified manifest by
`issued_at`, but only for the forced-update window; the installer and the
JIT refresh ignored it.

So whoever answers the device's `POST /manifest` could take a device back
to an older publish: a compromised or misconfigured update server, or a
man-in-the-middle when the endpoint is plain HTTP (the signature protects
integrity, not freshness). That reintroduces whatever the newer publish
fixed. Found in the Operator OTA review (operator commit 041305b).

## Decision

A device never installs, and never uses for JIT navigation, a manifest
older than the newest manifest it has verified.

* **The mark** is the gate's record (`Gate.newest/1`): the newest manifest
  verified on this device, installed or not, stored as the signed body and
  re-verified against the build's key, app and channel at every start.
  Reusing it means one definition of "newest" for both the gate and
  installs. The active slot is a second floor. (Originally one
  `<root>/gate.json`; see the amendment for where and how it's kept now.)
* **Order.** `check/0` records the fetched manifest with the gate first,
  then checks the floor. A newer manifest becomes the mark before its
  install is attempted, so a newer manifest that isn't installed
  (`:below_min_version`, `:rejected`, `:deferred`, `:stale_for_build`,
  `{:error, {:protected_modules, _}}`, a failed prefetch) still holds the
  floor above everything older. Since the amendment, nothing is used
  unless that record was persisted.
* **Equal `issued_at`.** The same manifest (same content id) fetched again
  is never refused: `{:ok, :current}` when active, otherwise whatever the
  normal pre-checks say. A *different* manifest with the same `issued_at`
  is refused, and the gate keeps the first one it verified (before this
  change it took the later one). Otherwise a replayer holding two
  publishes from the same second could alternate between them.
* **Rollback.** The watchdog's rollback reinstates the previous slot; it
  doesn't install, so the floor doesn't apply to it, and it never touches
  the gate's record, so it doesn't lower the mark. After rolling back from
  B to A, anything older than B is still refused. The active manifest
  always passes the floor: A served again is `:current` for `check/0` and
  usable by the JIT refresh, not reported as a replay.
* **Refusal.** `{:error, {:downgrade, %{id, issued_at, newest_id,
  newest_issued_at}}}` from `check/0` and from `resolve/1`'s refresh,
  plus a `Logger.error` naming both manifests. Nothing is downloaded.
  An error rather than an `{:ok, _}` outcome: a refused replay is either
  an attack or an operator mistake, and the poller logs errors.

## Consequences

* **Backing out a bad update means publishing again.** Copying an old
  manifest file back onto the server only reaches devices that never
  fetched the newer one. The watchdog still rolls back crashing updates on
  its own.
* **Two publishes in the same second conflict.** `mob_deliver_server`'s
  publish task stamps `issued_at` to the second. A device that saw one
  refuses the other. Follow-up for mob_deliver_server (MOB-486): make a
  publish's `issued_at` later than the manifest it replaces.
* **A future-dated publish pins the floor.** A manifest signed on a
  machine whose clock is ahead holds every device that fetched it above
  later publishes until that time. Recovery: publish with an explicit
  later `issued_at` (`MobDeliverServer.build/2` takes `:issued_at`). That
  publish is in the future too, so every publish until the bad time has
  passed needs an explicit `issued_at` after the previous one; the
  mob_deliver_server follow-up above (an `issued_at` later than the
  manifest it replaces) removes the need. The device can't tell a skewed
  clock from a real later publish, and its own clock isn't trustworthy
  either, so no cap is applied.
* **What it doesn't stop.** A device that has never seen the newer
  manifest can still be served an older one: first contact, a fresh
  install, or an attacker who controls every response since the newer
  publish. Freshness for those needs an expiry or a signed "latest" from
  a trusted clock, which v1 doesn't have. HTTPS remains the advice.
  Delivered code running in a session can rewrite the mark, as it can any
  store file; it is trusted by construction
  (`2026-10-02-delivered-code-threat-model.md`). The floor is against
  whoever serves manifests, not against code already running.

## Amendment (2026-11-14): the floor fails closed and is kept per channel

Found in the adversarial review of the static-endpoint change
(`2026-11-13-static-endpoint.md`), which relies on this floor to refuse a
stale or replayed file from a static host. The floor as first built could
be lowered after a restart:

* `check/0` and the JIT refresh only logged a failed `gate.json` write and
  went on; the gate updated memory, so the session refused older
  manifests, but the next launch didn't know the newer one.
* At start, a missing, corrupt or unverifiable `gate.json` left the gate
  empty. The active slot was the only floor left, so with A (`issued_at`
  1) active and B (3) verified but not installed (a failed prefetch,
  below `min_app_version`, deferred, rolled back), an older C (2) passed:
  newer than A.
* There was one `gate.json`. A build on another channel rejected it (wrong
  channel) and replaced it, so production → beta → production forgot the
  production floor.

Decision:

* **Nothing is used unless its record is persisted.** `Floor.record/3`
  (called by `check/0` and the refresh before anything else) returns
  `{:error, {:floor_not_persisted, reason}}`, logged as an error, unless
  the gate wrote the record; the manifest isn't installed or used. The
  record is in effect in memory either way (a higher floor only refuses
  more; dropping it would let this session accept something older than
  what it verified), and every later `Gate.record/3` retries the write
  first and fails until it succeeds. So while the gate can't write,
  nothing is installed or refreshed; the device keeps what it runs.
* **Two copies per app and channel**: `<root>/gate/<key>.json` and
  `<root>/gate/<key>.copy.json`, `key` the SHA-256 of app and channel (so
  neither can name a path). Both are written (atomically, each) for a
  record to count as persisted.
* **Recovery at start.** The record is the newest manifest that verifies
  (key, app, channel; signature first) among: every copy in `gate/`, the
  `gate.json` older versions wrote (read, never written; how upgrading
  devices keep their floor), and the store's persisted active and previous
  slots. Copies that don't hold it are rewritten. Records of other apps or
  channels fail verification as a mismatch and are kept, silently, for
  when the build is on that channel again.
* **Corrupt state can't brick updates.** A source that doesn't verify is
  skipped (logged), never trusted: the floor is always a manifest this
  build verifies, so at worst the device behaves as if it never saw what
  was lost. No unsigned record (the watchdog's rejections hold ids, not
  signed `issued_at`s) is used as a floor: a damaged one could otherwise
  pin the device above every real publish.

What it still doesn't stop: losing both copies of the record, and the
newer manifest not being in a slot, is a partial data wipe; the device
then knows only what it runs, like a fresh install. So is a launch that
ends before a failed write was retried (the device refused the manifest,
and never acted on it, but forgets it saw it). Both need the device's own
storage to fail or be wiped; a server or a static host can't cause either.
