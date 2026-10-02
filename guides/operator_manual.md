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
| signing key | CI secret | private half signs manifests; public half is in the app's config, shipped inside the native build |

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

**Rotation needs a store release.** The public key ships inside the app
binary (its config is part of the native build, and delivered code can't
replace it), and a manifest carries one signature. To rotate: ship an app version
with the new key, then publish new manifests with the new key on a separate
channel (or once every supported app version has the new key). Old binaries
keep accepting only the old key — if it leaks, the remedy is a store update
plus `min_app_version`/`force_update_after` (below) to retire old binaries.

## 2. App configuration

Needs mob 0.9.6 or later with its mob_dev. mob_dev evaluates
`config/config.exs` (merged with `config/runtime.exs` if present) **on the
build machine** for the build's Mix env and ships the result inside the
app; mob loads it before any plugin starts. Values are fixed at build
time, and code in those files runs on your machine, not the phone.

```elixir
# mob.exs
config :mob, :plugins, [:mob_deliver]

# config/config.exs
config :mob_deliver,
  trusted_publish_key: "ed25519:…",       # ships in the native build
  app: "com.example.myapp",               # must match what you publish
  channel: :production,
  endpoint: "https://example.com/deliver",
  # CA certificates for HTTPS (required on Android, harmless on iOS)
  req_options: [
    connect_options: [
      transport_opts: [cacerts: for({:cert, der, _} <- :public_key.cacerts_get(), do: der)]
    ]
  ],
  store_url: "https://apps.apple.com/app/id000000000"
  # app_version: "1.4.0"                  # overrides Mob.Device.app_version/0
```

If `endpoint`, `app`, `channel` or `trusted_publish_key` is missing on the
device, mob_deliver logs `mob_deliver: not configured (…)` naming the
keys, runs the bundled code, leaves its stored state alone, and
`MobDeliver.check/0` returns `{:error, :not_configured}`.

**TLS on Android.** The BEAM can't read Android's trust store, so without
CA certificates every HTTPS request fails (`{:error, {:transport, _}}`;
for a missing trust store the error wraps Mint's "default CA trust store
not available"). The `req_options` above embed the build machine's CA
certificates (DER) in the shipped config; rebuild to pick up changes, or
list your own DER certificates to pin CAs. `Mob.Certs.load_cacerts!/1`
(a bundled `priv/cacerts.pem` loaded into `:public_key`) works too, but
only once the app's `on_start` has run it, which is after the plugin's
boot-time check has started. Prefer `req_options`.

Boot the app through the update gate:

```elixir
def on_start do
  {:ok, _} = Mob.Screen.start_root(MobDeliver.root_screen(MyApp.HomeScreen))
end
```

Where screens live decides how they ship: modules under `lib/` are compiled
into the store build; modules under `mobile/` (outside `elixirc_paths`) are
never bundled and only reach devices through publishing. Navigating to a
`mobile/` screen fetches it on first use, including one published after
the device's last update: once the app's first screen has rendered, a
navigation to a module the device doesn't know asks the server for its
newest manifest (at most once per `:refresh_interval`, default 30s) and
takes just that screen's modules from it. During startup (before that
first frame) only installed content runs, so a screen the startup flow
needs must be in an installed manifest (it is after the next update
check).

Bundled code (`lib/`) can call a delivered module (`mobile/`) directly, but
the compiler can't see `mobile/`, so it warns that the module is undefined
on every compile and publish. Silence it per module where you call it:

```elixir
defmodule MyApp.HomeScreen do
  use Mob.Screen
  # Delivered from mobile/ by mob_deliver; not compiled into lib/.
  @compile {:no_warn_undefined, MyApp.Greeting}

  defp greeting, do: MyApp.Greeting.text()
end
```

Such a call is exactly what runs on the boot path, so a broken delivered
module is caught by probation (section 6). mob_deliver loads it at launch
once an update check has installed a manifest with it; before that (the
first launch, or no network yet) the call raises `UndefinedFunctionError`,
so guard it (`function_exported?/3` after `Code.ensure_loaded/1`) if the
app must run without it.

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

**A new build outranks older delivered code.** When a device runs a build
(a store update, `mix mob.deploy --native`, or a BEAM push with
`mix mob.deploy`) whose bundled version of a module differs from the one
the active manifest was installed on, that manifest is stale for the
build: at the next launch the device runs its bundled code, logs
`mob_deliver: this build's bundled code is newer than manifest …`, and
won't install that manifest again (`check/0` → `{:ok, :stale_for_build}`),
nor a re-publish that still ships those module versions. Nothing is
rejected and the user sees no rollback notice. To deliver updates on top
of the new build, publish again from the source that build was made from;
that installs normally.

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
  `:update_screen`), and any navigation mid-session replaces the whole
  navigation stack with it, so back can't return to a user screen. Set
  `store_url`: without it the screen can only tell users to find the app
  in their store.
* `--min-app-version` must be dotted numeric (`1.5.0`). A device that
  can't compare it with its own version leaves the gate open and logs a
  `mob_deliver:` warning naming the value.

The gate follows the newest manifest a device has verified and survives
restarts and offline launches; an older signed manifest can't lift it.
When a newly verified manifest makes the gate required, the app switches
to the update screen at once; when a newer one lifts it (publish without
`--min-app-version`, or with a lower one), an app showing the update
screen goes back to its root screen at once, also right after a cold boot
that started on the update screen. That needs the app to boot through
`MobDeliver.root_screen/2`, which is how it knows the root.

## 6. What devices do

* **When they check:** at launch, every `:poll_interval` (default one hour;
  `false` turns timed checks off) **while the app is in the foreground**,
  and on a silent push. `MobDeliver.check/0` runs one on demand.
  * *Background:* Android blocks the network of an app in the background
    (Android 15: requests outside a valid process lifecycle fail, see
    [background network access restrictions](https://developer.android.com/about/versions/15/behavior-changes-all#background-network-access);
    earlier versions cut it in
    [Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)).
    So timed checks
    pause when the app is backgrounded; on return to the foreground a
    check runs at once if one came due meanwhile.
  * *Silent push* (with `mob_wake` installed): a push whose data carries
    `"mob_wake_id": "mob_deliver_check"` runs a check. On Android it must be
    a **data-only, high-priority** FCM message. FCM "attempts to deliver
    high priority messages immediately, allowing FCM to wake a sleeping
    device when necessary and to run some limited processing (including
    very limited network access)", and gives the handler only several
    seconds
    ([FCM: Android message priority](https://firebase.google.com/docs/cloud-messaging/android-message-priority)).
    With `mob_push`, send a map with `content_available: true`, a `data`
    map, and **no** `:title`/`:body`/`:subtitle`/`:sound`/`:badge` keys;
    only then does it build a data-only message with `android.priority:
    "high"`:

    ```elixir
    MobPush.send(android_token, :android, %{
      content_available: true,
      data: %{"mob_wake_id" => "mob_deliver_check"}
    })
    ```

    `MobWake.wake_payload/2` adds `title`/`body` placeholders, which make
    `mob_push` send a visible notification on Android instead, so drop them
    (`Map.drop(payload, [:title, :body])`) for Android tokens. On iOS send
    the `wake_payload` as is (`content-available: 1`). Treat pushes as a
    best-effort nudge: the check has to finish inside that short window,
    and FCM deprioritizes high-priority messages that don't lead to a
    visible notification. The foreground checks are what's guaranteed.
* **What they fetch:** the manifest, plus new versions of modules the device
  already runs, delivered modules that code running in the app *calls*
  (e.g. a bundled screen calling a delivered helper), and the delivered
  modules those call, so the next launch has them offline. Modules nothing
  on the device calls (including screens that are only navigated to) are
  fetched the first time they're navigated to.
* **When updates apply:** at the next launch. A running session keeps its
  loaded code, and on mob that's every bundled module (all loaded at
  launch); only modules not loaded yet (a JIT screen not opened this
  session) use the new manifest at once. So an update installed while the
  app runs applies at its next launch, and one published while the app was
  closed needs two: the launch's own check installs it, the one after runs
  it. `MobDeliver.check(details: true)` and `MobDeliver.state/0` report
  `restart_required` so the app can offer "Restart to update" (the ADR's
  "Updates and relaunches" explains why code isn't swapped mid-session).
* **Probation:** the first launch of a new manifest is on probation until the
  root screen paints (first idle). If that launch dies first, the next launch
  rolls back to the previous manifest, refuses what that update introduced
  (below), and `MobDeliver.take_rollback_notice/0` returns a one-time
  notice to show the user. Only one unproven update is installed at a time.
  While one is pending, further checks are deferred with exponential
  backoff (5s, doubling, capped at `:poll_interval`). A launch that boots
  into the forced-update screen doesn't count either way: the update stays
  on probation until a launch shows the app's real root screen.
* **Any death before first idle counts.** The device can't tell a crash in
  your delivered code from an OS kill, a user swiping the app away, or a
  crash in bundled code or a native library during that launch. All of
  them roll the update back and reject its content on that device. The
  window is short (launch to the root screen's first paint), but it
  happens.
* **Fixing a rolled-back release: change the broken module.** When an
  update X is rolled back, the device records the module versions X
  brought to it (compiled `.beam`s that differ from the release it
  replaced and that weren't already on the device) **and that the failed
  launch actually loaded** — typically the changed boot-path modules, not
  screens nobody opened or that the device already had. On that app
  version it refuses every later manifest that still contains *all* of
  those versions, whatever its `issued_at` or update window and whatever
  else changed. So re-running the publish on the same source, or shipping
  a release that only changes other modules, does nothing for those
  devices; the log names the modules (`refusing … any manifest that still
  has all of …`). Change at least one of those — normally the one that
  crashed — and the release is installed and gets its own probation. A
  source change counts only if it changes the compiled `.beam` (not a
  comment-only edit). If the failed launch ran nothing X brought (killed
  before loading any), only that exact manifest is refused. After a store
  update of the app, devices give previously rejected content, even the
  unchanged manifest, a fresh probation. Devices that rejected content
  under mob_deliver 0.1.0 refuse that exact manifest on every app version;
  the same modules re-published get one more probation launch there.
* **Moving only the update window:** a manifest with exactly the modules
  the device already runs (and has proven) is adopted at once, with no
  probation launch, so publishing just to set or lift
  `--min-app-version`/`--force-update-after` doesn't hold up the next
  update.

## 7. Troubleshooting

Device logs are prefixed `mob_deliver:`. `MobDeliver.check/0` returns why
nothing changed:

| Result | Meaning |
|---|---|
| `{:error, :not_configured}` | `endpoint`, `app` or `channel` unset on the device (logged); needs mob ≥ 0.9.6 to ship config |
| `{:error, :no_trusted_publish_key}` | the app was built without `trusted_publish_key` |
| `{:error, :invalid_signature}` | manifest signed with a different key than the app's |
| `{:error, {:app_mismatch, _}}` / `{:channel_mismatch, _}` | published `--app`/`--channel` differ from the app config |
| `{:error, {:http_status, 404}}` | no manifest for that app + channel on the server |
| `{:error, {:transport, _}}` | network/TLS — on Android check the `req_options` CA certs (section 2); in the background, see section 6 |
| `{:ok, :below_min_version}` | this binary is older than the manifest's floor |
| `{:ok, :deferred}` | an installed update hasn't finished its probation launch yet |
| `{:ok, :rejected}` | the manifest still ships every module version a rolled-back update introduced on this device (log: `refusing … any manifest that still has all of …`); change one of them |
| `{:ok, :stale_for_build}` | the manifest ships module versions this device's build has newer bundled code for (section 4); publish from the build's source |
| `{:error, {:protected_modules, keys}}` | the manifest would replace mob_deliver's, mob's or the app config's own code (or Elixir/crypto); never installed — remove those modules from what you publish |

A navigation that does nothing logs `mob_deliver: navigation to X refused,
it couldn't be delivered (reason)` (the same reasons as above). A module
the server didn't have yet logs `mob_deliver: X isn't in the manifest
fetched Ns ago; next refresh allowed in Ms` (see `:refresh_interval`)
before the router's own "unknown navigation destination" error.
