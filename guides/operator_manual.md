# Operator manual

How to run over-the-air delivery for a mob app: signing key, app
configuration, a delivery endpoint, publishing, and what devices do with it.
Design details live in
[`decisions/2026-09-19-scope-and-wire-format.md`](../decisions/2026-09-19-scope-and-wire-format.md).

## Pieces

| Piece | Where it runs | What it does |
|---|---|---|
| `mob_deliver` | on the device (plugin) | fetches the signed manifest, verifies it, fetches and loads `.beam`s, rolls back failed updates, gates outdated apps |
| `mob_deliver_server` | your build machine / CI (`mix mob_deliver.publish`) and your server (`MobDeliverServer.Plug`) | compiles `mobile/`, signs a manifest, writes blobs; serves `POST /manifest` and `GET /beam/:sha256` |
| signing key | CI secret | private half signs manifests; public half is compiled into the app |

Any server that speaks the wire format works — `mob_deliver_server` is the
reference implementation, not a requirement.

## 1. Signing key (once per app)

```bash
mix mob_deliver.gen.key --out mob_deliver_signing.key
```

Writes the private key (mode `0600`, never overwrites) and prints
`trusted_publish_key: "ed25519:…"` for the app config. Keep the private key
out of version control and store its contents as a CI secret
(`MOB_DELIVER_SIGNING_KEY`).

**Rotation needs a store release.** The public key is compiled into the app
binary, and a manifest carries one signature. To rotate: ship an app version
with the new key, then publish new manifests with the new key on a separate
channel (or once every supported app version has the new key). Old binaries
keep accepting only the old key — if it leaks, the remedy is a store update
plus `min_app_version`/`force_update_after` (below) to retire old binaries.

## 2. App configuration

```elixir
# mob.exs
config :mob, :plugins, [:mob_deliver]

# config/config.exs
config :mob_deliver,
  trusted_publish_key: "ed25519:…",       # compile time
  app: "com.example.myapp",               # must match what you publish
  channel: :production,
  endpoint: "https://example.com/deliver",
  app_version: "1.4.0",                   # this binary's store version
  store_url: "https://apps.apple.com/app/id000000000"
```

Boot the app through the update gate:

```elixir
def on_start do
  {:ok, _} = Mob.Screen.start_root(MobDeliver.root_screen(MyApp.HomeScreen))
end
```

On Android (or anywhere the BEAM has no system trust store) pass a CA bundle
through `req_options`, e.g. `req_options: [connect_options: [transport_opts:
[cacerts: MyApp.cacerts()]]]` — see `Mob.Certs`.

Where screens live decides how they ship: modules under `lib/` are compiled
into the store build; modules under `mobile/` (outside `elixirc_paths`) are
never bundled and only reach devices through publishing. With mob's router
hooks, navigating to a `mobile/` screen fetches it on first use; on older mob
call `MobDeliver.resolve(MyApp.SomeScreen)` before navigating.

## 3. Delivery endpoint

Mount the plug in a Phoenix app (outside the `:browser` pipeline):

```elixir
forward "/deliver", MobDeliverServer.Plug,
  storage: {MobDeliverServer.Storage.FS, root: "/srv/mob_deliver"}
```

* `GET /beam/:sha256` is immutable (`max-age=31536000, immutable`, strong
  ETag) — a CDN can cache it indefinitely.
* `POST /manifest` is `no-cache`; it needs a server (a pure static host
  can't answer a POST).
* Serve over HTTPS. The signature protects integrity regardless, but TLS
  keeps delivered code private and stops trivial replay of an old manifest.
* For S3/GCS, implement `MobDeliverServer.Storage` and call
  `MobDeliverServer.build/2` + `publish/2` from your own task.

## 4. Publishing

From the **app project** (so `mobile/` compiles against the exact
dependencies the shipped binary has):

```bash
MOB_DELIVER_SIGNING_KEY="$(cat mob_deliver_signing.key)" \
  mix mob_deliver.publish --app com.example.myapp --channel production \
    --out mob_deliver_publish
```

then copy `mob_deliver_publish/` to the server's storage root (or point the
plug's `Storage.FS` root at it). Keep the output **outside `priv/`**: mob_dev
copies the app project's whole `priv/` into the native binary, so publishing
there would bundle the delivered screens into the next store build. Blobs are
written before the manifest, so a server never advertises a module it can't
serve.

Keep the toolchain fixed: the same source with the same Elixir/OTP produces
the same SHAs. Delivered code must be built with the Elixir/OTP and plugin
versions of the binaries in the field — a module that calls a NIF the
installed binary doesn't have fails when loaded; use the update window below
for changes like that.

Today the publish task compiles `mobile/` only; OTA fixes to bundled `lib/`
modules are supported by the client but need a custom build list
(`MobDeliverServer.build/2` accepts a list of files).

## 5. Update window

```bash
mix mob_deliver.publish … --min-app-version 1.5.0 \
  --force-update-after 2026-11-01T00:00:00Z
```

* Apps below `min_app_version` don't install that manifest.
* Before `force_update_after` they report `{:recommended, info}` from
  `MobDeliver.update_status/0` — show a banner whose button calls
  `MobDeliver.open_store/0`.
* After it, they boot into `MobDeliver.UpdateRequiredScreen` (or your
  `:update_screen`) and, with router hooks, can't navigate to user screens.

The gate follows the newest manifest a device has verified and survives
restarts and offline launches; an older signed manifest can't lift it.

## 6. What devices do

* **When they check:** at launch, every `:poll_interval` (default one hour;
  `false` turns timed checks off), and on a silent push: with `mob_wake`
  installed, a push whose data carries `"mob_wake_id": "mob_deliver_check"`
  (e.g. built with `MobWake.wake_payload(:mob_deliver_check, …)` and sent via
  `mob_push`) runs a check. `MobDeliver.check/0` runs one on demand.
* **What they fetch:** the manifest, plus new versions of modules the device
  already runs and the delivered modules those call. Modules nothing on the
  device uses are fetched the first time they're navigated to.
* **When updates apply:** at the next launch. A running session keeps its
  loaded code; modules not loaded yet resolve to the new manifest at once.
* **Probation:** the first launch of a new manifest is on probation until the
  root screen paints (first idle). If that launch dies first, the next launch
  rolls back to the previous manifest, never installs the failed one again,
  and `MobDeliver.take_rollback_notice/0` returns a one-time notice to show
  the user. Only one unproven update is installed at a time.
* **Fixing a rolled-back release:** publish new content. The same content is
  refused by every device that rolled it back.

## 7. Troubleshooting

Device logs are prefixed `mob_deliver:`. `MobDeliver.check/0` returns why
nothing changed:

| Result | Meaning |
|---|---|
| `{:error, :no_trusted_publish_key}` | the app was built without `trusted_publish_key` |
| `{:error, :invalid_signature}` | manifest signed with a different key than the app's |
| `{:error, {:app_mismatch, _}}` / `{:channel_mismatch, _}` | published `--app`/`--channel` differ from the app config |
| `{:error, {:http_status, 404}}` | no manifest for that app + channel on the server |
| `{:error, {:transport, _}}` | network/TLS — on Android check `req_options` CA certs |
| `{:ok, :below_min_version}` | this binary is older than the manifest's floor |
| `{:ok, :deferred}` | an installed update hasn't finished its probation launch yet |
| `{:ok, :rejected}` | this content was rolled back on this device before |
