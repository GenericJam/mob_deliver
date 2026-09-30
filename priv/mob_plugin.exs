%{
  name: :mob_deliver,
  # The real floor (mob 0.9.6) is the mix.exs dependency; this stays loose
  # so builds against an unreleased mob checkout (still versioned 0.9.5)
  # pass manifest validation.
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
    # Boot-time entry: re-verify the content-addressed store, roll back an
    # update that never reached first idle, load delivered code, hook the
    # router, start update checks. Never raises or hangs; on any failure
    # the app runs its bundled code. mob starts the :mob_deliver OTP
    # application (and its deps) and loads the app config before this.
    on_start: {MobDeliver, :on_start, []},
    # Timed update checks pause in the background (Android blocks a
    # backgrounded app's network) and catch up on return.
    on_resume: {MobDeliver, :on_resume, []},
    on_background: {MobDeliver, :on_background, []}
  }
}
