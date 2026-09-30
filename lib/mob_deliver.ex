defmodule MobDeliver do
  @moduledoc """
  Content-addressed BEAM delivery for Mob apps — proactive OTA updates *and*
  JIT screen delivery.

  Two triggers, one primitive:

  * **Update poll** — at boot, on a schedule, or on a silent push (via
    `mob_wake`), fetch the current manifest, prefetch cold modules,
    signature-verify each `.beam`, hot-load in place.
  * **JIT navigation** — `Mob.Router` calls `MobDeliver.resolve/1` on a
    cache miss. Fetch the one module (plus its transitive deps), verify,
    load, mount. First-tap latency for uncached screens is one round-trip;
    subsequent visits are local.

  Same signing, same verification, same on-device content-addressed store
  under both. The wire format is deliberately protocol-not-library — the
  server-side companion (`mob_deliver_server`) is one convenient
  implementation, but any static server hosting SHA-addressed BEAMs plus a
  signed manifest works.

  Design + scope + wire format v1: `decisions/2026-09-19-scope-and-wire-format.md`.

  ## Which plugin do I actually want?

  MobDeliver sits alongside the notify/push/wake/background quartet at the
  same layer of the ecosystem — it's the "how does my app change after
  install" plugin.

  | I want to…                                                | Plugin                                              |
  |-----------------------------------------------------------|-----------------------------------------------------|
  | **Deliver new/updated Elixir code** (screens, logic, migrations) to shipped apps without a store update | **`mob_deliver`** (this plugin) |
  | Wake the app on a schedule / silent push to run a handler | [`mob_wake`](https://hexdocs.pm/mob_wake)           |
  | Keep the app alive while backgrounded                     | [`mob_background`](https://hexdocs.pm/mob_background) |
  | Send a push from my server                                | [`mob_push`](https://hexdocs.pm/mob_push)           |
  | Register for pushes / schedule local notifications        | [`mob_notify`](https://hexdocs.pm/mob_notify)       |

  A silent-push-driven update flow uses `mob_wake` to schedule the check
  and `mob_deliver` to actually pull + install; the two compose naturally.

  ## What ships in v1

  * Content-addressed on-device BEAM store.
  * Manifest fetch + Ed25519 signature verification against a trusted key
    baked into the shipped app.
  * Per-module hot-load via `Code.load_binary/3` (no restart when nothing
    on the `on_start` path changed).
  * Slot-based watchdog + rollback for updates that DO touch boot: if a
    fresh install crashes before the app reaches its first idle, next boot
    detects it and swaps back to the last-known-good tree.
  * `MobDeliver.resolve/1` — cache-miss fetch, callable from a router.
  * Forced-update window: manifest carries `min_app_version`; clients below
    the floor get a graceful N-day nag then hard-stop with a
    "please update from the store" screen.
  * Server-side companion library (`mob_deliver_server`, separate) that
    turns a Phoenix project's `mobile/` source tree into a signed
    content-addressed publish.

  ## What v1 explicitly does NOT do

  Recorded as future-work possibilities in the ADR, not implemented:

  * Cross-plugin NIF capability negotiation (the "user has mob_camera 0.1.7
    but manifest ships modules built against 0.1.8" case). v1's answer:
    NIF / BEAM-runtime changes require a store update — force-window'd.
  * Multi-target publish (per-client-version content variants).
  * Percentage / cohort rollouts.
  * Session-affinity latching for mid-session module updates.
  * Poisoned-SHA client cache metadata.
  * Delta-encoded bundles between versions.

  See `decisions/2026-09-19-scope-and-wire-format.md` for the full
  rationale on why these are punted and what wire-format hooks are
  already in place to let each one land as an additive change later.
  """

  alias MobDeliver.Client

  # Baked in at compile time: the trust root ships inside the reviewed binary
  # and can't be swapped by anything delivered later.
  @trusted_publish_key Application.compile_env(:mob_deliver, :trusted_publish_key)

  @doc """
  Fetches the current manifest for this app + channel and verifies its
  signature against the compile-time `:trusted_publish_key`.

      config :mob_deliver,
        trusted_publish_key: "ed25519:<base64 raw 32-byte public key>",
        app: "com.example.myapp",
        endpoint: "https://updates.myapp.com",
        channel: :production,
        # optional, merged into the Req request (TLS trust, timeouts, …)
        req_options: []

  Returns `{:error, :no_trusted_publish_key}` without touching the network
  when no key was configured at build time.
  """
  @spec fetch_manifest() :: {:ok, MobDeliver.Manifest.t()} | {:error, Client.error()}
  def fetch_manifest do
    :mob_deliver
    |> Application.get_all_env()
    |> Keyword.take([:app, :endpoint, :channel, :req_options])
    |> Keyword.put(:trusted_publish_key, @trusted_publish_key)
    |> Client.fetch_manifest()
  end
end
