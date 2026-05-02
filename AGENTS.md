# AGENTS.md — OpenCode Session Guide

## Repo purpose

Cross-distro package system: builds emulators once per `build_target` (on `ubuntu:latest`), publishes as `.deb`/`.rpm`/`.pacman` to `gh-pages`. All builds run on GitHub Actions — no local build/test/lint.

## Single source of truth

Never hardcode values that exist in:
- `devices.yml` — `build_targets:` (arch, cflags, runner) + `devices:` (hardware, power score, `build_target` mapping)
- `distros.yml` — target distros with `enabled:` flag
- `emulators.yml` + `packages.yml` — build entries (`emulators/<id>/build.sh` or `packages/<id>/build.sh`)

Adding anything = edit YAML, add script if needed, commit. CI picks it up.

## Critical constraints

- **Zero hardcoded values** — derive everything from YAML configs
- **Surgical edits only** — copy existing code, change what differs
- **Build scripts run in Docker** (`emu-deps-image`) with env vars: `TARGET_ID`, `TARGET_ARCH`, `TARGET_CFLAGS`, `TARGET_DEVICES`, `SOURCE_DISTRO`, `VERSION`/`COMMIT`, `CCACHE_DIR=/ccache`, `BUILD_TIMEOUT`
- **Script contract**: populate `/tmp/pkg/{meta,root}/`, call `scripts/emit-aliases.sh`, tar to `*.pkg.tar`, write `completed` to `/workspace/build-status`
- **`.pkg.tar` is intermediate** — not Pacman; output is `.pkg.tar.zst`

## Common pitfalls

- `local` only works inside functions — scripts use top-level variables deliberately
- `$GITHUB_TOKEN` is repo-scoped — don't send to external APIs
- Don't `cd` without returning — use absolute paths or `$OLDPWD`
- Guard matrix jobs: `if: fromJSON(...)[0] != null`
- `per_device: true` = one build per device (e.g. `setperf`); otherwise one build per `build_target`
- `noarch_single_build: true` = single build emits arch=all packages for all devices

## Build pipeline summary

1. **prepare** — fetches versions, compares `.trackers/*`, bin-packs into 4 chains × 2 levels (`ind`/`dep`), produces matrix per `(emulator × build_target)`
2. **chain-N-{ind,dep}** — runs `build.sh` in Docker, emits `*.pkg.tar` + status
3. **update-repo-seed** → **update-repo** — converts to all enabled formats; seed device first (builds shared deps), rest serialize
4. **save-trackers** — commits updated `.trackers/*` to `main`

See `CLAUDE.md` for detailed pipeline and dependency resolution docs.

## Commands

No local commands. All verification via GitHub Actions logs.

## Files that matter

- `.github/workflows/build-emulators.yml` — main workflow
- `.github/workflows/build-chain.yml` — reusable build job
- `.github/workflows/update-repos.yml` — format conversion + publish
- `scripts/compute-chains.sh` — matrix generation logic
- `scripts/resolve-deps.sh` — dependency resolution
- `scripts/dep-map.conf` — cross-distro name mapping
- `scripts/dep-ignore.conf` — version-irrelevant deps

## Commit style

English messages, no `Co-Authored-By` trailer.
