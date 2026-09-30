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
time, hot-load via `Code.load_binary/3`.

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
- Per-module hot-load via `Code.load_binary/3` (no app restart when
  nothing on the `on_start` path changed).
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

# config/config.exs — the trust root for THIS app's deliverables
config :mob_deliver,
  # Compile time: baked into the reviewed binary. "ed25519:" <> base64 of the
  # raw 32-byte public key.
  trusted_publish_key: "ed25519:<base64-of-your-app's-Ed25519-public-key>",
  app: "com.example.myapp",
  endpoint: "https://updates.myapp.com",
  channel: :production,
  # Optional, merged into every Req request — e.g. `connect_options:
  # [transport_opts: [cacerts: ...]]` where the BEAM has no system trust store.
  req_options: []
```

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
Read [`AGENTS.md`](AGENTS.md) and the scope ADR before changing anything
wire-format-adjacent.

## License

MIT — see [`LICENSE`](LICENSE).
