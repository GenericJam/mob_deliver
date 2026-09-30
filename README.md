# mob_deliver

Content-addressed BEAM delivery for [Mob](https://hexdocs.pm/mob) apps —
proactive OTA updates *and* JIT screen delivery. "Your mobile app can be
a website."

> **Status: v0.1.0-dev.** Design + scope + wire format v1 are pinned in
> [`decisions/2026-09-19-scope-and-wire-format.md`](decisions/2026-09-19-scope-and-wire-format.md).
> Implementation is tracked as child issues of the `mob_deliver-c67` beads
> epic. Not yet usable in an app; no Hex release yet.

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

## Installation (once shipped to Hex)

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
  # The native app version (mob can't read it at runtime) and store page,
  # for the forced-update window.
  app_version: "1.4.0",
  store_url: "https://apps.apple.com/app/id000000000",
  # Optional:
  poll_interval: :timer.hours(1),  # false = only boot + push checks
  on_push: true,                   # register the mob_wake :mob_deliver_check handler
  stable_after: 5_000,             # ms until "first idle" if mark_stable/0 isn't called
  # Merged into every Req request — e.g. `connect_options:
  # [transport_opts: [cacerts: ...]]` where the BEAM has no system trust store.
  req_options: []
```

## Usage

```elixir
# The app's on_start — the plugin's own on_start has already verified the
# store, rolled back a failed update if needed, and loaded delivered code.
def on_start do
  {:ok, _} = Mob.Screen.start_root(MobDeliver.root_screen(MyApp.HomeScreen))
end

# On mob without router hooks (0.9.4 and earlier) only — newer mob ends the
# update's probation at the root screen's first paint by itself:
MobDeliver.mark_stable()

# Once per launch, e.g. in the root screen's mount:
if MobDeliver.take_rollback_notice(), do: show_notice("Your last update failed and was rolled back.")

case MobDeliver.update_status() do
  {:recommended, _info} -> show_update_banner()  # its button calls MobDeliver.open_store()
  _ -> :ok
end

# On mob without router hooks only — newer mob runs this (and the update
# gate) before every navigation by itself:
:ok = MobDeliver.resolve(MyApp.ExpansionScreen)
```

Update checks run at boot, every `:poll_interval`, and on a silent push
whose data carries `"mob_wake_id": "mob_deliver_check"` (with `mob_wake`
installed). `MobDeliver.check/0` runs one now.

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
