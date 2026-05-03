# Changelog

All notable changes to AstralEmu Packages are tracked here. Dates are in
ISO 8601 (YYYY-MM-DD).

## Unreleased

### Fixed

- **Docker cache key bumped to v8** — previous v7 cache predates the `zstd`
  CLI package addition, causing `kernel-*-prep` jobs to fail with `zstd: not
  found` when packing the patched source tarball. The new key forces a rebuild
  of both the amd64 and arm64 images.
- **intel-media-driver CMake** — added `-DMEDIA_RUN_TEST_SUITE=OFF` to skip
  the ULT (unit level testing) subdirectory whose CMakeLists.txt has a broken
  `if()` on undefined variables when building in Release mode.
- **Flycast libretro core** — replaced the Makefile-based `build_core` call with
  a CMake build (`-DLIBRETRO=ON`). The `flyinghead/flycast` repo uses CMake,
  not a Makefile — the previous check for `$name/Makefile` immediately
  errored out.

### Added — Custom kernel stack

A complete kernel build pipeline covering every supported handheld:

- **`kernel-amd64`** — Linux stable for x86 handhelds (Steam Deck, ROG Ally,
  Legion Go, MSI Claw, GPD Win, AYANEO, OneXPlayer, AYN Loki). BORE
  scheduler + CachyOS portable patches + the CachyOS handheld driver
  patch (`<X.Y>/misc/0001-handheld.patch`) which provides the
  Steam Deck `hwmon` / LEDs / `extcon` / `mfd` stack, ROG Ally / Legion
  Go / MSI Claw / Zotac Zone HID drivers, AMDGPU display panel quirks
  and AW87xxx audio codec.
- **`kernel-arm64-modern`** — Linux stable for armv8.2-a flagships
  (Retroid Pocket 5/6, AYN Thor, Orange Pi 5, Snapdragon 845-X3 generic).
  BORE + CachyOS portable + ROCKNIX downstream patches per-SoC
  (Qualcomm `qcom`, Rockchip, Samsung).
- **`kernel-arm64-legacy`** — Linux stable for armv8-a A53/A55/A57/A72/A73
  handhelds (Anbernic RG35XX series, Powkiddy V90/X55, Odroid Go Super,
  Raspberry Pi 4). Same global patch set + ROCKNIX downstream patches
  (Rockchip, Amlogic, Allwinner).
- **`kernel-tegra-x1`** — Linux 4.9 specifically for the Nintendo Switch,
  sourced from `NaGaa95/switch-l4t-kernel-4.9` (the only actively
  maintained 4.9 fork, with 2026-04 commits adding `erista` support).
  Mainline 6.x is unusable on Tegra X1: NVIDIA's `nvgpu` Maxwell driver
  was never ported, and BORE / CachyOS patches don't apply on 4.9.
  No global patches here, just `CONFIG_HZ_1000=y` + `CONFIG_PREEMPT=y`.

The three modern kernels are split across five sub-jobs (`prep`, `image`,
`modules-soc`/`platform`, `modules-generic`, aggregator) so that no
single job comes close to the GitHub Actions 6h ceiling. `kernel-tegra-x1`
stays mono-job — the 4.9 tree builds in roughly an hour. A new
`target_filter` mechanism on `packages.yml` entries restricts a
multi-target chain to a subset of `build_targets` (used by the arm64
kernels and by `kernel-tegra-x1` to scope itself to the Switch only).

### Added — `kernel-astralemu-<device>` per-device meta-package

A single `apt install kernel-astralemu-<device>` (or dnf/pacman
equivalent) now pulls every device-specific piece of the kernel stack
in one shot: kernel + modules + dtbs (ARM only) + `setperf` +
`astralemu-deps-repo`. Switch (`l4t`) special-cases to
`kernel-tegra-x1`; everything else maps to its `build_target` flavor.
The vendor-firmware mapping (`astralemu-firmware-tegra` /
`-amd-handheld` / `-rockchip` / `-allwinner` / `-amlogic` /
`-qualcomm` / `-intel-meteorlake`) is kept in `firmware_for_device()`
as a commented-out template, ready to wire in when the corresponding
firmware packages land in a future commit.

### Added — `astralemu-deps-repo` (recreated)

The repo configuration meta-package — drops `apt/sources.list.d/`,
`yum.repos.d/`, `pacman.d/` config snippets pointing to the AstralEmu
shared deps repository for the current `source_distro`. Pulled in as
a hard dep by `kernel-astralemu`. Postinst auto-detects the package
manager and refreshes its index. Survives across rolling LTS bumps
because it keys on `${SOURCE_DISTRO}` rather than a frozen codename.

### Added — `setperf` no-op fallback for every device

`packages.yml` gains an opt-in `payload_optional: true` flag that opts
a per_device entry out of the subdir-presence filter in
`compute-chains.sh`. `setperf` uses it: devices without a hand-tuned
`packages/setperf/<device>/setperf` script now ship a no-op fallback
binary, so `kernel-astralemu`'s hard dep on `setperf` resolves on every
device repo (previously only `l4t` had a setperf published, leaving 25
devices unable to install the meta-package).

### Added — 26 device entries (19 named handhelds + existing baselines)

`devices.yml` gains concrete entries for the handheld lineup from the
kernel integration plan: Anbernic RG35XX original/H/SP/Plus, RG ARC,
RG406, Powkiddy V90/X55, Odroid Go Super, Retroid Pocket 5/6,
Orange Pi 5, AYN Thor, Steam Deck LCD/OLED, AYN Loki, ROG Ally / Ally X,
Legion Go / S, MSI Claw, GPD Win Mini/Max, OneXPlayer, OneXFly,
AYANEO Geek/Slide/Kun. The existing generic baselines (`x86-v2/v3/v4`,
`armv8-2`, `armv9`, `rpi4`, `l4t`) stay as fallbacks.

### Changed — Power scoring rescaled from 1-5 to 1-9

The new device lineup spans the whole spectrum from RK3326 (Cortex-A35,
score 1) to Strix Point / x86-64-v4 desktop-class silicon (score 9).
Both axes are now 1-9, the two scales remain independent — emulators
keep separate `power_arm` + `power_amd` thresholds. Steam Deck LCD/OLED
sit at 6 (Zen 2 mid-tier, the SteamOS canonical reference is no longer
the apex). Emulator thresholds recalibrated to reflect source-arch
dynarec asymmetries:

  - `azahar-emu` (3DS, ARM source)        2,1 → 3,4
  - `dolphin-emu` (Wii/GC, PowerPC)       3,2 → 4,3   Switch capable with the perf stack
  - `xemu` (Xbox OG, x86 source)          4,2 → 6,5   x86→ARM via QEMU TCG, Retroid Pocket 5 viable
  - `libretro-heavy-1/2/3`                3,2 → 4,3   tracks `dolphin-emu`
  - `perf-libs`                           3,2 → 1,3   Mesa-compat floor on each arch

### Added — Mirror filter (`include` / `exclude`) on `devices.yml` sources

The `theofficialgman/l4t-debs` mirror now ships only the actual L4T 32.7
stack — `nvidia-l4t-*`, `nvidia-bsp-*`, `cuda-cudart-*`, `switch-*`,
`joycond`, `xserver-xorg-*`, `nintendo-switch-meta`. The bundled
chromium / switch-flatpak / yt-dlp / libwidevinecdm0 / plymouth themes /
onboard / kscreen / appstream / `-dev` / `-doc` / `-dbg` / `-tests`
payloads are dropped (217 → 59 .deb on the current upstream snapshot,
146 → 37 distinct package names). The `mirror-devices.yml` workflow
also picks up `pool/main-<variant>/` subtrees automatically (R32.7 BSP).

### Changed — Source distros switched to rolling LTS aliases

The codename-pinned IDs (`resolute` / `trixie` / `ublue`) become stable
rolling aliases (`ubuntu-lts` / `debian-stable` / `fedora-latest`). The
underlying Docker base images carry the rolling tag (`ubuntu:latest`,
`debian:latest`, `fedora:latest`, `archlinux:latest`) so an Ubuntu LTS
or Fedora rollover no longer requires a manual bump in this repo. Hash-
only versioning + automatic republish absorbs the typical ABI breaks
(libavcodec60 → libavcodec61 etc.). For the Fedora DNF tree, we serve
a single rolling path under `dnf/.../latest/<arch>/` rather than per-
Fedora-version subdirs.

`scripts/dep-ignore.conf` parser also gains glob support so entries
like `ubuntu-wallpapers-*` match every codename rollover without
needing a new line per LTS.

### Changed — Kernel package names made canonical

The four kernel build aggregators (`kernel-amd64`, `kernel-arm64-modern`,
`kernel-arm64-legacy`, `kernel-tegra-x1`) now write `meta/name` as the
plain canonical name rather than `kernel-<target>-${TARGET_ID}`. The old
form expanded to e.g. `kernel-arm64-legacy-arm64-legacy` (because in
non-per_device mode `TARGET_ID == build_target.id`), so the canonical
short name `kernel-astralemu` actually depends on existed nowhere. The
device-specific Provides aliases (`kernel-arm64-legacy-l4t`, etc.) are
still emitted by `emit-aliases.sh` so legacy lookups keep working.

### Changed — `kernel-amd64` patch source: Valve → CachyOS handheld

The `kernel-amd64-prep` build was cloning
`github.com/ValveSoftware/linux-integration` which returns 404 — Valve
removed the GitHub mirror. The current SteamOS 3 source mirror lives
on the Holo `gitlab.steamos.cloud/jupiter/linux-integration.git` GitLab
instance which requires authenticated access, so it's not viable for
an unattended CI clone either. Switched the AMD handheld driver / display
quirk / audio codec coverage to CachyOS/kernel-patches'
`<X.Y>/misc/0001-handheld.patch`. The two unique kernel features Valve
still ships that CachyOS doesn't — AMD P-State EPP handheld profile and
NTSYNC sync primitive — have both been upstream since 6.18-6.19, so on
the kernel versions ROCKNIX pins us to nothing functional regresses.

### Added — Triple MAME ROMset windows in `libretro-heavy-1`

`mame2003-plus-libretro` (ROMset 0.78) is intentionally frozen on the
pre-2003 arcade catalogue. Added `mame2010-libretro` (ROMset 0.139) and
`mame2016-libretro` (ROMset 0.174) alongside it so users can pick the
ROMset window that matches their library without rebuilding their image.
All three forks are actively maintained on github.com/libretro.

### Changed — `duckstation` / `duckstation-deps` track `master`

`emulators.yml` had `version_branch: latest`, which is a *tag* of a
rolling release on `stenzek/duckstation`, not a branch. The CI's GitHub
API call resolves git refs and may or may not pick the right thing
depending on whether the API treats `latest` as a branch or a tag.
Switched both entries to `version_branch: master` for an unambiguous,
always-resolvable git ref.

### Changed — `flycast` cloned from flyinghead upstream

`libretro/flycast` is deprecated (the libretro README explicitly redirects
to `flyinghead/flycast`). Generalised `build_core()` in
`libretro-heavy-2/build.sh` to accept `<org>/<repo>` as the first argument
and use that for flycast. Default behaviour (clone from
`libretro/<repo>`) is unchanged for every other core.

### Added — License retention in standalone emulator packages

`scripts/finalize-meta.sh` now accepts an optional second argument
`<src_dir>` and, when present, scans the upstream tree for the canonical
LICENSE / COPYING / NOTICE / COPYRIGHT / AUTHORS files and stages them
under `<pkg_root>/usr/share/doc/<pkg_name>/`. The 7 standalone emulator
build scripts (`azahar-emu`, `dolphin-emu`, `duckstation`,
`emulationstation-de`, `melonds`, `ppsspp`, `xemu`) each pass their
matching `/workspace/src-<id>` directory. Brings the `.deb` / `.rpm` /
`.pkg.tar.zst` we publish into compliance with GPL §1's requirement
that binaries ship with the upstream copyright notice. Libretro cores
and `perf-libs` are NOT yet covered — their per-core/per-lib build
patterns need a separate retention pass.

### Removed — `BUILD_TIMEOUT` escape hatch

The 5h30 internal timeout that used to mark builds as `timeout` and exit
0 (so the chain wouldn't fail) has been removed. It silently masked real
job failures at the 6h GitHub ceiling. Splitting heavy builds across
multiple jobs is now the only correct answer; jobs that legitimately
need more than 3h are split further.

### Added — `scripts/sync-rocknix-kernels.sh` helper

Pulls per-SoC patches from `ROCKNIX/distribution`
(`projects/ROCKNIX/devices/<SoC>/patches/`) and DTS overlays into the
matching `packages/kernel-arm64-*/patches/soc-downstream/<SoC>/`. The
ROCKNIX kernel version is read dynamically from `package.mk` so a
ROCKNIX bump propagates automatically through `.trackers/`.

### Added — `docs/tegra-x1-research.md`

Full ecosystem research for the Switch L4T stack: why mainline 6.x is
not viable today (`nvgpu` upstream gap), why Linux 4.9 is the only
realistic target, why BORE/CachyOS don't apply, and a deferred PoC
plan to revisit a mainline 6.x port once the upstream Tegra DRM /
Nouveau Maxwell story matures.

### Fixed — kernel builds, flycast, and patch tolerance

- Added missing `zstd` CLI to the amd64 Docker image used for packing kernel source tarballs
- Auto-create missing `drivers/net/ethernet/nvidia/eqos/Kconfig` in the NaGaa95/switch-l4t-kernel-4.9 tree
- Auto-create missing `drivers/firmware/tegra/Kconfig` (referenced by `arch/arm64/Kconfig:1236`)
- `apply_patches_dir` now resolves rejected `.rej` hunks for Makefile/Kconfig files: `obj-*` and
  `source ""` lines that fail to apply at the original offset are reinserted at the correct
  location, so out-of-tree patches that drift across kernel versions no longer silently drop
  build entries
- BORE is no longer silently skipped when the firelzrd repo lacks the current kernel version:
  falls back to the CachyOS BORE patch (`<X.Y>/sched/0001-bore.patch`), and hard-fails if
  no BORE source exists for the target kernel — no kernel ships without an optimized scheduler
- Flycast: robust git submodule init with depth-limited retry and critical-dep verification
  before CMake runs
