# Nothing older than the newest verified manifest is used (replay floor)

- Date: 2026-10-15
- Status: accepted
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
  verified on this device, installed or not, stored as the signed body in
  `<root>/gate.json`, re-verified against the build's key, app and channel
  at every start. Reusing it means no second file, no migration (devices
  upgrading keep the newest they had), and one definition of "newest" for
  both the gate and installs. The active slot is a second floor: if the
  gate file is lost or fails to verify, the device still never goes below
  what it runs.
* **Order.** `check/0` records the fetched manifest with the gate first,
  then checks the floor. A newer manifest becomes the mark before its
  install is attempted, so a newer manifest that isn't installed
  (`:below_min_version`, `:rejected`, `:deferred`, `:stale_for_build`,
  `{:error, {:protected_modules, _}}`, a failed prefetch) still holds the
  floor above everything older.
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
  refuses the other. Follow-up for mob_deliver_server: make a publish's
  `issued_at` later than the manifest it replaces.
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
