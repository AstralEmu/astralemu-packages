# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Cross-distro package conversion system that builds emulators and performance-critical libraries once (on a `source_distro`, currently `resolute`/Ubuntu 26.04 LTS) and republishes them as `.deb`, `.rpm`, and Pacman repos — one per device — on the `gh-pages` branch. Served at `https://astralemu.github.io/astralemu-packages/`.

There are no tests, no linter, no local build. All builds run on GitHub Actions. Local work is config/script editing plus reading recent Actions logs.

## Single source of truth — don't hardcode

Everything flows from three YAML files. Never hardcode values that exist here:

- [devices.yml](devices.yml) — two sections:
  - `build_targets:` — unique compilation configs (`id`, `arch`, `cflags`, `platform`, `runner`, `base_image`, `source_distro`). Currently `amd64`, `arm64-legacy`, `arm64-modern`.
  - `devices:` — hardware units (`id`, `name`, `build_target`, `power`, optional `sources`). Multiple devices can share one build_target — the resulting package carries `Provides:` aliases so legacy device-named installs keep working.
- [distros.yml](distros.yml) — target distributions with an `enabled: true/false` flag per entry. Disabled distros are skipped by the CI while staying referenced by `dep-map.conf`.
- [emulators.yml](emulators.yml) + [packages.yml](packages.yml) — build entries (merged at runtime by [scripts/compute-chains.sh](scripts/compute-chains.sh)). Same schema, different base dir (`emulators/<id>/build.sh` vs `packages/<id>/build.sh`). Special flag: `per_device: true` forces one build per hardware device instead of per build_target (used by `setperf` whose content is hardware-specific).

Adding a device / distro / emulator is: edit the YAML, add the build script if applicable, commit. CI picks it up.

## Build pipeline (big picture)

The main workflow is [.github/workflows/build-emulators.yml](.github/workflows/build-emulators.yml). It is not a simple matrix — it's a chain/wave scheduler:

1. **prepare** — fetches upstream versions, compares against `.trackers/*`, bin-packs build entries into 4 parallel chains × 2 levels (`ind` = independent, `dep` = depends_on another emulator). Aggregators (e.g. `libretro-package`) run last and download sibling artifacts. Skip decisions use cache keys named `success-<id>-<hash>` where `<hash>` covers both `build.sh` and the YAML entry. One matrix entry is produced **per (emulator × build_target)** — not per device — except for `per_device: true` packages.
2. **chain-N-ind / chain-N-dep** — reusable workflow [.github/workflows/build-chain.yml](.github/workflows/build-chain.yml) runs each entry's `build.sh` inside a prebuilt Docker image (`emu-deps-image`, one per arch) with env vars `TARGET_ID`, `TARGET_ARCH`, `TARGET_CFLAGS`, `TARGET_CXXFLAGS`, `TARGET_DEVICES` (comma-separated alias list), `SOURCE_DISTRO`, `VERSION`/`COMMIT`/`SHORT`, `CCACHE_DIR=/ccache`, `BUILD_TIMEOUT`. Scripts must emit `*.pkg.tar` (intermediate format) and write `completed` to `build-status`. Artifacts are named `pkg-<emulator>-<target_id>`.
3. **update-repo-seed** + **update-repo** — the reusable [.github/workflows/update-repos.yml](.github/workflows/update-repos.yml) converts `.pkg.tar` to all **enabled** target formats. Each device downloads two artifact patterns: `pkg-*-<build_target>` (shared binaries) and `pkg-*-<device_id>` (per_device like setperf). The **seed device** (first in `devices.yml`) runs first, then the rest serialize (`max-parallel: 1`) so they can reuse the shared-deps repo built by the seed.
4. **save-trackers** — commits updated `.trackers/*` back to `main`.

### Seed strategy inside a single device

Within `update-repos.yml`, the first format built is the one most distant from `source_distro` (e.g. source=deb → seed=pacman). Builds later formats after the seed so the dep cache is fully populated. Don't "fix" this ordering without understanding why — it avoids redoing dependency resolution across formats.

## Intermediate `.pkg.tar` format

All build scripts emit a plain tar with `meta/` and `root/`:

- `meta/name`, `meta/version`, `meta/arch`, `meta/description`, `meta/maintainer`, `meta/depends` (one per line), `meta/source_format`, `meta/source_distro`, optional `meta/scripts/{preinst,postinst,prerm,postrm}`, `meta/conffiles`.
- `root/` — the filesystem tree to install (e.g. `root/usr/bin/foo`).

[scripts/pkg-extract.sh](scripts/pkg-extract.sh) converts any of `.deb`/`.rpm`/`.pkg.tar.zst` into this layout. [scripts/pkg-build-{deb,rpm,pacman}.sh](scripts/) convert the intermediate to the corresponding native format. Architecture names are normalized (`arm64`↔`aarch64`, `amd64`↔`x86_64`).

## Dependency resolution

[scripts/resolve-deps.sh](scripts/resolve-deps.sh) runs per target distro. When a dependency is missing or has an incompatible version on the target, it's fetched from `source_distro`, rebuilt with a `{source_distro}-` prefix (e.g. `resolute-libfoo`), and the `Provides:` field retains the original name. Prefixed packages land in a shared deps repo at `{format}/deps/{source_distro}/` — devices sharing a `source_distro` share this repo.

Two config files gate this behavior:
- [scripts/dep-map.conf](scripts/dep-map.conf) — cross-distro name mapping for ABI-sensitive libraries (e.g. `libc6` → `glibc` on rpm/pacman).
- [scripts/dep-ignore.conf](scripts/dep-ignore.conf) — packages whose version doesn't matter for dependents (skipped entirely).

Flags worth knowing: `--cache-dir` (reuse fetched source packages across runs), `--prefix` (override the default `{source_distro}-` prefix), `--existing-repo` (reuse already-published prefixed packages).

## gh-pages layout

```
{apt,dnf,pacman}/device/<device_id>/...   # emulator packages per device
{apt,dnf,pacman}/deps/<source_distro>/... # shared rebuilt dependencies
```

Do not write into `gh-pages` manually — the workflow publishes and signs (GPG) it. `main` holds sources + `.trackers/` only.

## Build script contract

Inside the Docker container `emu-deps-image` (base deps pre-installed, see [build-emulators.yml](.github/workflows/build-emulators.yml)), with `cd /workspace`:

- Compile with `-flto=thin` (clang) or `-flto` (gcc), link with `-ljemalloc` — enforced by each script, not by the workflow.
- Use `$CCACHE_DIR=/ccache` and respect `$BUILD_TIMEOUT` (exit 0 and write `timeout` to `/workspace/build-status` on timeout so ccache still saves).
- Populate `/tmp/pkg/{meta,root}/`, write `meta/name` as `<basename>-${TARGET_ID}`, then call [scripts/emit-aliases.sh](scripts/emit-aliases.sh) `<basename> <meta_dir>` to emit `Provides:`/`Replaces:` entries for every device sharing this build_target (legacy name compatibility). Finally `tar cf /workspace/<name>-<target>_<version>_<arch>.pkg.tar -C /tmp/pkg meta root`.
- Write `completed` to `/workspace/build-status` on success. The chain workflow scans for `*.pkg.tar` and these status files to decide the job outcome.

Package names are now `<emulator>-<target_id>` (e.g. `azahar-emu-arm64-legacy`). Legacy `-<device>` names resolve transparently through the aliases emitted by `emit-aliases.sh`. `per_device: true` packages (setperf) keep the `<emulator>-<device_id>` form since `TARGET_ID == device_id` in that mode.

## House rules (from memory)

- Zero hardcoded values — always derive from the YAML configs.
- Surgical edits only. Copy existing code and change what differs; do not rewrite entire scripts.
- Commit messages in English, no `Co-Authored-By` trailer.
- Prefer clean/official solutions over hacks.

## Common pitfalls

- `local` only works inside functions — the bash scripts here use top-level variables deliberately.
- `$GITHUB_TOKEN` is scoped to this repo; don't send it to external APIs (upstream emulator repos, mirrors).
- Don't `cd` without returning — CI scripts assume a stable `$PWD`. Use absolute paths or `$OLDPWD`.
- Guard matrix jobs with `if: fromJSON(...)[0] != null` — GitHub Actions errors on an empty matrix.
- `.pkg.tar` is *not* a Pacman package — it's the intermediate tarball. Pacman output is `.pkg.tar.zst`.
