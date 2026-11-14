# Static endpoints: the manifest as a file

- Date: 2026-11-13
- Status: accepted

## Context

Wire format v1 fetches the manifest with `POST /manifest` (app and channel
in the body) and blobs with `GET /beam/:sha256`. A POST needs a server.
Apps whose authors run no server of their own (FMutate, and the other
family apps) want to host delivered code on GitHub: GitHub Pages, a
release, or any bucket. None of them answers a POST.

The POST was never load-bearing. The server answers one manifest per app
and channel (no client capability negotiation in v1), and
`mob_deliver_server`'s publish already writes exactly that manifest to a
file: `manifests/<app>/<channel>.json`, next to `beam/<sha>`
(`MobDeliverServer.Storage.FS`).

A static host brings two things a server doesn't:

* **Stale copies are normal.** GitHub Pages answers with
  `Cache-Control: max-age=600` and a CDN in front; for up to ten minutes
  after a publish some devices are served the previous manifest, and a
  device can see the new one from one edge and the old one from the next.
  A request's `Cache-Control: no-cache` asks caches to revalidate, but a
  CDN may ignore it, and query-string cache busting isn't reliable either
  (Pages' CDN served a `?t=` variant from cache when we tried).
* **Whoever controls the files controls the replies.** Anyone with push
  access to the branch, or a compromised host, can put an older signed
  manifest back. A signature never expires, so it verifies.

## Decision

**`config :mob_deliver, endpoint_type: :static`** makes the client fetch
the manifest with `GET <endpoint>/manifests/<app>/<channel>.json`
(`Accept` as for the POST, `Cache-Control: no-cache`; app and channel
percent-encoded as one path segment each). Everything else is unchanged:
the body is the same signed manifest, verified against the build's key,
app and channel before any field is used; blobs are still
`GET <endpoint>/beam/<sha256>` and hashed on receipt; install, probation,
rollback, the update gate and JIT refresh are the same code. The default,
`:server`, keeps `POST /manifest`. An unknown value disables the plugin at
boot (`{:invalid_endpoint_type, value}`, logged with what to fix), like a
malformed key.

So the static layout is `mob_deliver_server`'s publish directory, uploaded
as it is. No second format, no new publish tool.

**Freshness is the replay floor's job, unchanged.** No new `sequence`
field: `issued_at` is already signed, already monotonic per device, and
the replay floor (`2026-10-15-replay-floor.md`, `MobDeliver.Floor`)
already refuses any manifest older than the newest one the device has
verified, or a different one with the same `issued_at`, persisted across
restarts and never lowered by a rollback. A stale CDN copy and a replayed
publish are the same event to the device: an older signed manifest. Both
are refused with `{:error, {:downgrade, info}}` before anything is
downloaded; the device keeps what it runs and picks up the newer publish
at the next check that reaches a fresh copy. A second counter would need
its own persistence and migration and would order exactly what `issued_at`
orders.

The refusal stays an error (logged) in static mode too. On a static host a
stale copy shortly after a publish is expected; it shows up at most for
the cache lifetime and only on devices that already saw the newer file.
Logging it differently by endpoint type would make a real replay on a
static host look routine.

## Consequences

* Hosting needs no code: GitHub Pages (a `gh-pages` branch), a bucket, or
  `python -m http.server` for a test all work. HTTPS is still the advice
  (it keeps a device that has never seen the newest publish from being
  served an older one; the floor can't cover first contact).
* A publish reaches devices only when the cache lets it: up to the host's
  cache lifetime (ten minutes on GitHub Pages) plus the host's deploy time.
* Publish blobs before the manifest and keep old blobs published while a
  device might still fetch a manifest that names them (the
  `mob_deliver.prune` grace-period rule). On a branch-backed host, commit
  blobs and manifest together; a Pages deploy switches the whole site at
  once.
* Two publishes must not share an `issued_at` second and a publish must be
  later than the one it replaces (the replay floor ADR's follow-up,
  MOB-486: `mob_deliver_server` after 0.2.0 dates a publish after the
  manifest it replaces, GenericJam/mob_deliver_server#2; 0.2.0 stamps the
  current second).
* JIT refresh (`resolve/1` of a screen the active manifest doesn't have)
  reads the same file and is refused the same way when it's stale.
