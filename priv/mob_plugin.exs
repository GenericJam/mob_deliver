%{
  name: :mob_deliver,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  description:
    "Content-addressed BEAM delivery for Mob apps — proactive OTA updates + " <>
      "JIT screen delivery. Wire format v1 in decisions/.",
  # No NIFs. mob_deliver is pure Elixir on the device side — it uses
  # Code.load_binary/3, Mob.data_dir/0, and standard :public_key / :crypto
  # from the OTP runtime for signature verification.
  nifs: [],
  # No plugin-declared permissions. Network access is via Req (the HTTP
  # stack mob apps already ship on-device); TLS trust options come from the
  # host through `config :mob_deliver, :req_options`. The manifest fetch
  # endpoint is app-configured, not framework-declared.
  # Note about the trust key: mob_deliver's own manifest (this file) is
  # signed by the shared mob first-party key for plugin-load verification.
  # That's a DIFFERENT trust root than the one an app uses to sign its own
  # deliverable BEAMs — that key is app-declared at compile time (see
  # `config :mob_deliver, :trusted_publish_key, ...`).
  lifecycle: %{
    # Boot-time entry: initialise the content-addressed store, load the
    # currently-active manifest into ETS, arm the watchdog if any pending
    # slot promotion needs completing. Idempotent + fast; safe to call
    # even when the plugin's runtime path is absent (host tests).
    on_start: {MobDeliver, :on_start, []}
  }
}
