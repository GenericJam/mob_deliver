# Delivered code is trusted in-session; the trust root is the build

- Date: 2026-10-02
- Status: accepted (review finding, accepted, not fixed)

## Context

Review of 71de7a2 (MOB-357 follow-up). mob_deliver reads its trust settings
(`trusted_publish_key`, `app`, `channel`, `app_version`) from the build's
`mob_app_config` module instead of the application environment, so a
delivered module calling `Application.put_env(:mob_deliver,
:trusted_publish_key, other_key)` no longer changes which manifests verify.

The finding: delivered code can still get around that within its session.
It can load its own binary over `mob_app_config` with `:code.load_binary/3`,
put a directory ahead of the build's on the code path, or purge the module
so it looks absent. `MobDeliver.Protected` only stops a **manifest** from
delivering those modules. It doesn't stop code that is already running from
calling the code server.

## Threat model

* **The boundary is the signature.** Code reaches a device only in a
  manifest signed by the publisher's key, which is checked against the key
  in the signed native build. Once delivered code runs, it is the app's
  own code. It runs in the same BEAM VM with the same privileges as the
  bundled code and mob_deliver, just like a dependency compiled into the
  binary.
* **Containing code inside one session is not a goal.** The BEAM has no
  isolation between modules. Code that sets out to subvert mob_deliver
  can load modules, rewrite ETS and `persistent_term`, call
  `:sys.replace_state/2` on its processes, or simply write the store
  files. No check made from inside the VM can stop that. A snapshot of
  the key, held anywhere the VM can reach, is no harder to change than
  the module.
* **What is guaranteed: nothing done in a session persists past the
  launch.** On every boot the trust settings are read from files in the
  signed native build, which the store can't replace. Mob loads app code
  from the binary's own directory, and the store isn't on the code path.
  A manifest can never deliver `mob_app_config`, `MobDeliver.*`,
  `Mob.*`, `:mob_nif` or the runtime's crypto modules (`Protected`, at
  install, in the JIT refresh and in the loader). So whatever key a
  session ends up with, the next launch starts from the build's key
  again, and a store update with a new key stops old-key manifests from
  verifying.
* **If the publish key leaks**, the attacker can ship code, and that code
  is trusted in-session by construction. The way out is a store update
  with a new key (operator manual, "Rotating the key"). Nothing inside the
  VM could do better.

## Decision

Accept the finding. Reading the trust settings from `mob_app_config`
rather than `Application.get_env` is **defence in depth, not a boundary**.
It stops accidental or opportunistic changes (a library calling
`put_env`, test helpers leaking into a build, a misguided runtime
override). It doesn't stop code that is deliberately hostile, and it
isn't meant to.

One cheap change that is safe to make came out of the review. On a device
(`:mob_nif.platform/0` answers `:android` or `:ios`), a missing
`mob_app_config` now means **nothing is trusted**: the plugin reports
itself not configured instead of falling back to the application
environment. Making the module look absent therefore can't reopen the
`put_env` path. Off-device (host tests, dev), the environment is still
used. On a phone with mob ≥ 0.9.6 the module is always shipped, and a
build without it has no `config :mob_deliver` on device anyway, so a
correctly built app sees no difference.

## Consequences

* Don't add in-VM hardening (key snapshots, checksums of loaded modules,
  watching the code server) in the name of this threat. It would cost
  complexity and buy nothing against code that already has VM privileges.
* Review what goes into a signed manifest as you would review code going
  into a store build. Publishing is releasing.
