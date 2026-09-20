# Agent instructions

Start with [`AGENTS.md`](AGENTS.md) — mob_deliver-specific orientation.
**Then read [`decisions/2026-09-19-scope-and-wire-format.md`](decisions/2026-09-19-scope-and-wire-format.md)** — it's the load-bearing document for what's in v1 vs future work. Everything else defers to it.

Also read `~/code/mob/AGENTS.md` + `~/code/mob/CLAUDE.md` for the system view and `~/code/mob/MOB_PLUGINS.md` for the manifest schema.

Pre-commit checklist (same as mob):

```bash
mix test
mix format
mix credo --strict   # includes ExSlop + jump_credo_checks
mix compile --warnings-as-errors
```

Not yet published to Hex; kept git-local while the scaffold + child issues land per `feedback_git_local_during_scaffold`.

Releases (once ready): mix.exs version bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish). See `~/code/mob/RELEASE.md` for the trigger model; do NOT bump versions without explicit permission.
