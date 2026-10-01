# mob_deliver

Content-addressed BEAM delivery for [Mob](https://hexdocs.pm/mob) apps —
proactive OTA updates *and* JIT screen delivery. "Your mobile app can be
a website."

> **Status: v0.2.** Wire format v1 — design and scope in
> [`decisions/2026-09-19-scope-and-wire-format.md`](decisions/2026-09-19-scope-and-wire-format.md).
> Serve it with [mob_deliver_server](https://github.com/GenericJam/mob_deliver_server);
> generate a wired-up app with `mix mob.new my_app --deliver`.

## What it does

Every Mob app ships Elixir `.beam` files inside its store-reviewed native
binary. mob_deliver adds a **content-addressed on-device store** that both:

1. **Fetches new/updated BEAMs proactively** — at boot, on a schedule, on
   a silent push (via [`mob_wake`](https://hexdocs.pm/mob_wake)), or when
   the user asks. Signature-verified, hot-loaded module-by-module, with
   slot-based rollback if a boot-time change crashes the app.
2. **Fetches BEAMs on demand at navigation time** — a router cache miss
   pulls the one module the user just tapped, verifies, loads, mounts.
   Structure an app as a small shell + a growing fleet of JIT-fetched
   screens. First-launch download stays tiny; screens land as the user
   reaches them.

Both consume the same primitive: fetch a `.beam` by its SHA-256, verify
against a signed manifest whose trust key was baked into the app at build
time, load via `:code.load_binary/3`.

## Which plugin do I actually want?

| I want to…                                                | Plugin                                              |
|-----------------------------------------------------------|-----------------------------------------------------|
| Deliver new/updated Elixir code (screens, logic, migrations) to shipped apps without a store update | **`mob_deliver`** (this plugin) |
| Wake the app on a schedule / silent push to run a handler | [`mob_wake`](https://hexdocs.pm/mob_wake)           |
| Keep the app alive while backgrounded                     | [`mob_background`](https://hexdocs.pm/mob_background) |
| Send a push from my server                                | [`mob_push`](https://hexdocs.pm/mob_push)           |
| Register for pushes / schedule local notifications        | [`mob_notify`](https://hexdocs.pm/mob_notify)       |

A silent-push-driven update flow uses `mob_wake` to schedule the check
and `mob_deliver` to actually pull + install; they compose naturally.

## What's IN v1

- Content-addressed on-device BEAM store.
- Manifest fetch + Ed25519 signature verification against a trusted key
  baked into the shipped app.
- Delivered modules load at launch, before any app code runs; screens not
  on the device yet load on first navigation (`:code.load_binary/3`).
- Slot-based watchdog + rollback for updates that DO touch boot.
- `MobDeliver.resolve/1` — cache-miss fetch, callable from a router.
- Forced-update window: manifest carries `min_app_version` + a
  `force_update_after` timestamp. Clients below the floor get a graceful
  update-recommended banner, then a hard "please update" gate after the
  deadline. Same UX as every mobile OTA system in the wild.
- Companion server library (`mob_deliver_server`, separate) turns a
  Phoenix project's `mobile/` source tree into a signed publish.

## What's explicitly OUT of v1

Recorded as future-work in the ADR, wire-format hooks in place for each
to land later as an additive change:

- Cross-plugin NIF capability negotiation (v1's answer: bundle NIF
  changes into a store update, enforce via `min_app_version`).
- Multi-target publish (per-client-version content variants).
- Percentage / cohort rollouts.
- Session-affinity latching for mid-session module upgrades.
- Poisoned-SHA client cache metadata.
- Delta-encoded bundles between versions.

See [`decisions/2026-09-19-scope-and-wire-format.md`](decisions/2026-09-19-scope-and-wire-format.md)
for the full rationale on each and the manifest-schema fields already
reserved for them.

## Installation

Needs mob 0.9.6 or later (and the mob_dev that goes with it): it ships
`config/*.exs` to the device and starts plugin OTP applications before
their `on_start`. On older mob, mob_deliver logs why and the app runs its
bundled code.

```elixir
# mix.exs
def deps do
  [
    {:mob_deliver, "~> 0.1"}
  ]
end
```

```elixir
# mob.exs
config :mob, :plugins, [:mob_deliver]

# config/config.exs
config :mob_deliver,
  # Compile time: baked into the reviewed binary. "ed25519:" <> base64 of the
  # raw 32-byte public key. The trust root for THIS app's deliverables.
  trusted_publish_key: "ed25519:<base64-of-your-app's-Ed25519-public-key>",
  app: "com.example.myapp",
  endpoint: "https://updates.myapp.com",
  channel: :production,
  # CA certificates for HTTPS; required on Android (see below).
  req_options: [
    connect_options: [
      transport_opts: [cacerts: for({:cert, der, _} <- :public_key.cacerts_get(), do: der)]
    ]
  ],
  # The store page for the forced-update window. This binary's version is
  # read at runtime (Mob.Device.app_version/0); `app_version: "1.4.0"`
  # overrides it.
  store_url: "https://apps.apple.com/app/id000000000",
  # Optional:
  poll_interval: :timer.hours(1),  # while in the foreground; false = only boot + push checks
  refresh_interval: 30_000,        # min ms between manifest fetches caused by JIT misses
  on_push: true                    # register the mob_wake :mob_deliver_check handler
```

mob_dev evaluates `config/config.exs` (and `config/runtime.exs`, if you
have one) **on the build machine** and ships the result with the app, so
the values above are fixed at build time; anything you compute there runs
on your machine, not the phone.

### HTTPS on Android

Android keeps its trust store behind a Java API the BEAM can't read, so
without CA certificates every HTTPS request fails:
`{:error, {:transport, _}}` from `MobDeliver.check/0` (for a missing trust
store it wraps Mint's "default CA trust store not available" error).
The `req_options` above fix that: the list comprehension runs on the build
machine and embeds the CA certificates it trusts, DER-encoded, in the
shipped config; rebuild to pick up trust-store changes. It's harmless on
iOS. To pin your own CAs, list their DER certificates instead.

`Mob.Certs.load_cacerts!/1` (loading a `priv/cacerts.pem` into
`:public_key`, see its docs) also works without any `req_options`, but only
for requests made after it runs. It runs in your app's `on_start`, which
is *after* mob_deliver's boot-time update check has started, so that
first check can fail and the next one is an interval away. Prefer
`req_options`.

## Usage

```elixir
# The app's on_start — the plugin's own on_start has already verified the
# store, rolled back a failed update if needed, and loaded delivered code.
def on_start do
  {:ok, _} = Mob.Screen.start_root(MobDeliver.root_screen(MyApp.HomeScreen))
end

# Once per launch, e.g. in the root screen's mount:
if MobDeliver.take_rollback_notice(), do: show_notice("Your last update failed and was rolled back.")

case MobDeliver.update_status() do
  {:recommended, _info} -> show_update_banner()  # its button calls MobDeliver.open_store()
  _ -> :ok
end
```

Navigating to a screen that isn't on the device just works: mob's router
calls mob_deliver before mounting it, which fetches it (once the first
screen has rendered, asking the server for its newest manifest first if
the screen was published after the last install; during startup only
installed content runs). That fetch runs in the router, so navigation waits for it. If it
fails, the user stays on the current screen and a `mob_deliver:` warning
is logged. To show a spinner or a "couldn't load" message instead, call
`MobDeliver.resolve/1` from a `Task` before navigating (example in its
docs); never call it inline in a screen callback, which would freeze the
screen for the whole download. Past the forced-update deadline, any
navigation replaces the whole stack with the update screen, so back
can't return to a user screen; when a check finds the gate newly
required or lifted, the app switches to the update screen or back to its
root at once.

Bundled code calling a delivered (`mobile/`) module compiles with an
"undefined module" warning; silence it with
`@compile {:no_warn_undefined, MyApp.Greeting}` in the calling module
(details in the [operator manual](guides/operator_manual.md#2-app-configuration)).

Update checks run at boot, every `:poll_interval` **while the app is in
the foreground** (Android blocks a backgrounded app's network, so timed
checks pause in the background and catch up on return), and on a silent
push whose data carries `"mob_wake_id": "mob_deliver_check"` (with
`mob_wake` installed; best effort on Android, see the
[operator manual](guides/operator_manual.md#6-what-devices-do)).
`MobDeliver.check/0` runs one now.

## Guides

- [Operator manual](guides/operator_manual.md) — signing key, app config,
  hosting, publishing, the update window, what devices do, troubleshooting.
- [Store review](guides/store_review.md) — the App Store / Google Play rules
  on downloaded code, where mob_deliver sits, and reviewer-note text.

## Development

```bash
git clone https://github.com/GenericJam/mob_deliver && cd mob_deliver
mix deps.get
git config core.hooksPath .beads/hooks   # beads hooks + the mob pre-push gate
```

Gate (CI runs the same on every push and PR):

```bash
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
mix test
```

Issues are tracked with [beads](https://github.com/gastownhall/beads):
`bd ready` lists unblocked work, `bd list --parent mob_deliver-c67` the v1 epic.
Read `AGENTS.md` (repo root) and the scope ADR before changing anything
wire-format-adjacent.

## License

MIT — see [`LICENSE`](LICENSE).
