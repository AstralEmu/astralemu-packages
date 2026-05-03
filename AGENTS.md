# AGENTS.md — AstralEmu Packages

## Repo purpose

Cross-distro package system: builds emulators and performance libraries once per `build_target` (on `ubuntu:latest` Docker), publishes as `.deb`/`.rpm`/`.pacman` to `gh-pages`. All builds run on GitHub Actions — no local build/test/lint.

## Single source of truth

Never hardcode values that exist in:
- `devices.yml` — `build_targets:` (arch, cflags, runner) + `devices:` (hardware, power, `build_target` mapping)
- `distros.yml` — target distros with `enabled:` flag
- `emulators.yml` + `packages.yml` — build entries (`emulators/<id>/build.sh` or `packages/<id>/build.sh`)

Adding anything = edit YAML, add script if needed, commit. CI picks it up.

## Critical constraints

- **Zero hardcoded values** — derive everything from YAML configs
- **Surgical edits only** — copy existing code, change what differs; do not rewrite entire scripts
- **Build scripts run in Docker** (`emu-deps-image`) with env vars: `TARGET_ID`, `TARGET_ARCH`, `TARGET_CFLAGS`, `TARGET_CXXFLAGS`, `TARGET_DEVICES`, `SOURCE_DISTRO`, `VERSION`/`COMMIT`/`SHORT`, `CCACHE_DIR=/ccache`, `BUILD_TIMEOUT`
- **Script contract**: populate `/tmp/pkg/{meta,root}/`, call `scripts/emit-aliases.sh`, tar to `*.pkg.tar`, write `completed` to `/workspace/build-status`
- **`.pkg.tar` is intermediate** — not Pacman; output is `.pkg.tar.zst`. The pipeline transforms `.pkg.tar` into all target formats.

## Architecture

### Pipeline flow

1. **prepare** (`build-emulators.yml`) — fetches upstream versions via GitHub/GitLab API, compares against `.trackers/*`, bin-packs builds into 4 chains × 2 levels (`ind`/`dep`), produces matrix per `(emulator/package × build_target)`. Skips entries with matching `success-<id>-<target>-<hash>` cache markers.

2. **chain-N-{ind,dep}** (`build-chain.yml`) — runs each entry's `build.sh` inside Docker with env vars from the matrix. Emits `*.pkg.tar` + `build-status`. Aggregators (libretro-package, kernel-*) download sibling artifacts.

3. **update-repo-seed → update-repo** (`update-repos.yml`) — converts `.pkg.tar` to all enabled formats via `pkg-extract.sh` → `pkg-build-{deb,rpm,pacman}.sh`. Seed device first (builds shared deps repo), rest serialize. Runs `resolve-deps.sh` for cross-distro dependency bridging.

4. **save-trackers** — commits updated `.trackers/*` to `main`.

### Package naming

- Regular packages: `<basename>-<target_id>` (e.g. `dolphin-emu-arm64-legacy`)
- `per_device: true` packages: `<basename>-<device_id>` (e.g. `setperf-l4t`)
- `noarch_single_build: true` packages: single build emits one arch=all `.pkg.tar` per device internally (setperf, astralemu-deps-repo, kernel-astralemu)
- `emit-aliases.sh` appends Provides/Replaces for every device sharing the build_target so legacy device-named installs keep working

### Dependency resolution

`resolve-deps.sh` runs per target distro during update-repos. When a dependency is missing or has incompatible version on the target, it's fetched from `source_distro`, rebuilt with a `{source_distro}-` prefix (e.g. `ubuntu-lts-libfoo`), and the original name is kept in `Provides:`. Two config files:
- `scripts/dep-map.conf` — cross-distro name mapping (e.g. `libc6` → `glibc` on rpm/pacman). Format: `deb_name [rpm:rpm_name] [pac:pac_name]`
- `scripts/dep-ignore.conf` — packages whose version doesn't matter for dependents (CLI tools, data, apps). Same format. Glob patterns (e.g. `ubuntu-wallpapers-*`) are supported.

### Intermediate `.pkg.tar` format

All build scripts emit a plain tar with `meta/` and `root/`:
- `meta/name`, `meta/version`, `meta/arch`, `meta/description`, `meta/maintainer`, `meta/depends` (one per line), `meta/source_format`, `meta/source_distro`
- Optional: `meta/provides`, `meta/replaces`, `meta/conflicts`, `meta/scripts/{preinst,postinst,prerm,postrm}`, `meta/conffiles`
- `meta/provides.<distro>` and `meta/replaces.<distro>` — per-distro provides/replaces (used by perf-libs)
- `root/` — filesystem tree to install

`scripts/finalize-meta.sh` writes source_distro, source_format, and maintainer. Each build.sh calls it after creating package-specific fields.

### Kernel packages

Kernels use a 5-step split pattern (documented in `docs/kernel-integration-plan.md`):
- `<target>-prep` — clone + apply patches + savedefconfig
- `<target>-image` — compile kernel image + dtbs
- `<target>-modules-platform` (amd64) or `<target>-modules-soc` (arm64) — SoC/platform-specific modules
- `<target>-modules-generic` — net/usb/hid/sound/fs/crypto modules
- `<target>` (aggregator) — merges sub-job artifacts into final packages

`scripts/kernel-helpers.sh` is sourced by all kernel build scripts. It provides `resolve_kernel_version()`, `clone_linux_stable()`, `apply_patches_dir()`, `fetch_bore_patches()`, `fetch_cachyos_patches()`, `kernel_pkg_version()`.

`scripts/sync-rocknix-kernels.sh` pulls per-SoC kernel patches from the ROCKNIX distribution into `packages/kernel-<target>/patches/soc-downstream/`.

### perf-libs

The `perf-libs` package reads `packages/perf-libs/libraries.yml` for a dependency graph of performance-critical libraries (LLVM, Mesa, FFmpeg, etc.). Topologically sorted, each sub-library builds into `/opt/perf-libs-staging` and then the whole thing gets packaged. Emulators built with `-ljemalloc` and optimized flags link against these.

### Libretro aggregator pattern

`libretro-package` is the aggregator. The heavy/light cores build as `artifact_type: cores` (producing `.so` files, not `.pkg.tar`). The aggregator downloads all `libretro-cores-*` artifacts, bundles them into a single `.pkg.tar`, and provides the package name `libretro-cores`. When aggregator deps are marker-cached but the aggregator needs to rebuild, `compute-chains.sh` either pulls cores from the previous successful run's artifacts (fallback) or forces the deps to rebuild.

## Special YAML fields

| Field | Where | Purpose |
|---|---|---|
| `per_device: true` | emulators.yml/packages.yml | One build per device instead of per build_target |
| `noarch_single_build: true` | packages.yml | Single arch=all build that internally iterates devices.yml |
| `is_aggregator: true` | emulators.yml/packages.yml | Downloads sibling artifacts; runs after all chains |
| `artifact_type: cores` | emulators.yml | Produce `.so` files instead of `.pkg.tar` |
| `artifact_type: kernel-prep` / `kernel-image` / `kernel-modules` | packages.yml | Kernel sub-job artifact types |
| `target_filter: [arm64-modern]` | packages.yml | Restrict entry to specific build_targets |
| `payload_optional: true` | packages.yml | Don't filter per_device jobs for missing subdir (setperf fallback) |
| `depends_on: [id, ...]` | emulators.yml/packages.yml | Build after named entries complete |
| `extra_caches` | emulators.yml | Additional cache entries (key/path/mount/save) |
| `version_source: hash-only` | emulators.yml/packages.yml | No upstream version tracking; uses build hash for uniqueness |
| `version_source: github-commit` | emulators.yml | Track a branch by commit SHA; `SHORT` is first 7 chars |
| `version_source: github-release` / `gitlab-release` | emulators.yml | Track by release tag |

## Build script conventions

- `set -e` or `set -euo pipefail` at top
- Always `export PATH="/usr/lib/ccache:$PATH"` and `ccache -z`/`ccache -s`
- Clang builds use `-flto=thin`, GCC builds use `-flto`, all link with `-ljemalloc`
- Write `completed` to `/workspace/build-status` on success
- Libretro core builds write `completed` to `/workspace/build-status-heavy-N` instead
- For timeout: exit 0 and write `timeout` to build-status (so ccache still saves)
- Use `$TARGET_CFLAGS` / `$TARGET_CXXFLAGS` from matrix — these already exclude LTO flags (scripts add those)
- `perf-libs` sub-builds use clang/ThinLTO (`CC=clang`, `CXX=clang++`, `CC_LD=lld`, `CXX_LD=lld`)
- `finalize-meta.sh <meta_dir> [<src_dir>]` — writes source_distro/source_format/maintainer; optionally copies LICENSE files from src_dir

## Common pitfalls

- `local` only works inside functions — scripts use top-level variables deliberately
- `$GITHUB_TOKEN` is repo-scoped — don't send to external APIs (upstream repos, mirrors)
- Don't `cd` without returning — CI scripts assume a stable `$PWD`. Use absolute paths or `$OLDPWD`
- Guard matrix jobs with `if: fromJSON(...)[0] != null` — GitHub Actions errors on empty matrices
- Architecture normalization: `arm64`↔`aarch64`, `amd64`↔`x86_64` — `pkg-build-*.sh` and `pkg-extract.sh` handle this
- `SOURCE_DISTRO` env var is set by build-chain.yml from `build_targets[].source_distro` in devices.yml — scripts must not hardcode it
- `compute-chains.sh` uses `set -o pipefail` — avoid `... | head -1` pipelines (use variable capture instead)
- Debian `t64` suffix packages (Ubuntu 24.04 64-bit time_t transition) map to the same RPM/pacman packages in `dep-map.conf`
- The seed device (first in `devices.yml`) runs update-repo first to build the shared deps repo; all other devices serialize after it
- `noarch_single_build: true` forces a single amd64 build that internally iterates all devices; `per_device: true` creates one matrix entry per device

## gh-pages layout

```
{apt,dnf,pacman}/device/<device_id>/...   # emulator packages per device
{apt,dnf,pacman}/deps/<source_distro>/... # shared rebuilt dependencies
```

Do not write into `gh-pages` manually — the workflow publishes and GPG-signs it. `main` holds sources + `.trackers/` only.

## Version tracking

`.trackers/` stores the last-built version for each tracker (e.g. `dolphin-commit`, `azahar-version`). `compute-chains.sh` compares fetched versions against trackers to decide build/skip. After a successful build pipeline, `save-trackers` commits updated values back to `main`.

For `hash-only` packages, there's no upstream version — version uniqueness comes from the first 7 chars of the build hash: `1.0.0+<hash7>`.

## Files that matter

- `.github/workflows/build-emulators.yml` — main workflow (prepare + chains + deploy)
- `.github/workflows/build-chain.yml` — reusable build job (Docker matrix)
- `.github/workflows/update-repos.yml` — dependency resolution + format conversion + publish
- `.github/workflows/deploy-pages.yml` — generate device repo index pages
- `.github/workflows/mirror-devices.yml` — mirror external device source packages (e.g. L4T debs)
- `.github/workflows/rebuild-all.yml` — force-rebuild trigger
- `.github/workflows/cancel-all.yml` — cancel all running workflows
- `scripts/compute-chains.sh` — matrix generation, hash computation, bin-packing, skip logic
- `scripts/resolve-deps.sh` — cross-distro dependency bridging
- `scripts/dep-map.conf` — cross-distro package name mapping
- `scripts/dep-ignore.conf` — packages to skip during dep resolution
- `scripts/emit-aliases.sh` — write Provides/Replaces for device aliases
- `scripts/finalize-meta.sh` — write shared metadata fields
- `scripts/pkg-extract.sh` — extract any format → intermediate
- `scripts/pkg-build-{deb,rpm,pacman}.sh` — convert intermediate → native format
- `scripts/cross-pkg-helpers.sh` — library path relocation, script translation (deb↔rpm↔pacman)
- `scripts/kernel-helpers.sh` — kernel version resolution, patch fetching
- `scripts/report.sh` — GitHub Actions step summary helpers
- `scripts/sync-rocknix-kernels.sh` — pull ROCKNIX kernel patches
- `packages/perf-libs/libraries.yml` — perf-libs build graph and provides mapping

## Commit style

English messages, no `Co-Authored-By` trailer.

## Commands

No local build/test/lint commands. All verification via GitHub Actions logs. The workflows can be triggered via `workflow_dispatch` with optional `force` flag.

Useful local-only commands:
- `yq` and `jq` are required by `compute-chains.sh` (used in CI)
- `scripts/sync-rocknix-kernels.sh` can be run locally to update kernel patches