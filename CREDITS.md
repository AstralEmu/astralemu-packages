# Credits

This repository is, fundamentally, a *recompiler and mirror*. It rebuilds
upstream software with handheld-tuned compiler flags + a curated patch
stack, and republishes the result across `.deb`, `.rpm` and Pacman
formats — but it produces no original software. Every byte of code we
package, every patch we cherry-pick, every binary we mirror comes from
the projects listed below.

This file gives credit where it's due. If you want to ship something,
upstream the fix to the project that actually wrote the code, not to us.

> **License posture.** Every upstream we redistribute keeps its original
> license. We do not relicense anything. The license of each binary
> we publish is the license of its upstream — GPL v2 for the kernel,
> GPL v3 for FFmpeg's GPL build, MIT/Zlib/Apache for the various perf
> libraries, the emulators' own licenses, and so on. License files are
> retained inside every `meta/` payload we produce. Where we apply
> patches we keep the original `Signed-off-by` / copyright headers.

---

## Linux kernel

### Base kernel

- [**Linux**](https://kernel.org) — the kernel itself. Pinned to a
  specific stable release per `kernel-<target>` build; the version is
  read dynamically from the matching ROCKNIX `package.mk` so a ROCKNIX
  bump propagates here automatically.
  License: GPL-2.0-only.

### Scheduler and global performance patches

- [**BORE scheduler — `firelzrd/bore-scheduler`**](https://github.com/firelzrd/bore-scheduler)
  — Burst-Oriented Response Enhancer scheduler. Used in `kernel-amd64`,
  `kernel-arm64-modern` and `kernel-arm64-legacy` (skipped for
  `kernel-tegra-x1` — does not apply on 4.9). License: GPL-2.0-only.
- [**CachyOS portable kernel patches — `CachyOS/kernel-patches`**](https://github.com/CachyOS/kernel-patches)
  — selective MM/VM and core kernel cherry-picks (`<X.Y>/*.patch`).
  CPU-specific x86 patches filtered out on the arm64 builds. License:
  GPL-2.0-only.
- [**CachyOS handheld driver patch — `CachyOS/kernel-patches`**](https://github.com/CachyOS/kernel-patches)
  — `<X.Y>/misc/0001-handheld.patch`, the monolithic handheld driver
  series CachyOS ships for Steam Deck (`steamdeck-hwmon`, `leds-steamdeck`,
  `extcon-steamdeck`, `mfd/steamdeck`), ASUS ROG Ally (`hid-asus-ally`),
  Lenovo Legion Go (`hid-lenovo-go`, `hid-lenovo-go-s`), MSI Claw
  (`hid-msi-claw`), Zotac Zone (`zotac-zone-hid` / `-platform`), AMDGPU
  display panel/backlight quirks, AW87xxx audio codec, plus assorted
  Bluetooth / wireless patches for handheld radios. Used in
  `kernel-amd64` only. License: GPL-2.0-only.

### Per-SoC downstream patches and DTBs

- [**ROCKNIX — `ROCKNIX/distribution`**](https://github.com/ROCKNIX/distribution)
  (branch `next`) — every per-SoC downstream patch series we apply on the
  arm64 kernels comes from here, including the device-tree blobs.
  Synced via [`scripts/sync-rocknix-kernels.sh`](scripts/sync-rocknix-kernels.sh)
  from `projects/ROCKNIX/devices/<SoC>/{patches,linux/dts}/`. SoCs we
  pick from:
  - `kernel-arm64-modern`: RK3588, SM8550, SM8250, SM6115, RK3576, SM8650
  - `kernel-arm64-legacy`: H700, RK3326, RK3566, RK3399, S922X
  Cherry-picks retain their original `Signed-off-by:` lines.
  License: GPL-2.0-only.

### Nintendo Switch (Tegra X1) kernel

- [**`NaGaa95/switch-l4t-kernel-4.9`**](https://github.com/NaGaa95/switch-l4t-kernel-4.9)
  (branch `linux-dev`) — the only actively maintained Linux 4.9 fork
  for the Tegra X1, with 2026-04 commits adding `erista` support. Used
  in `kernel-tegra-x1`. The full ecosystem rationale lives in
  [`docs/tegra-x1-research.md`](docs/tegra-x1-research.md).
  License: GPL-2.0-only.
  Carries upstream NVIDIA L4T 32.x patches; `nvgpu` binary blob is **not
  redistributed by us** — it ships through the filtered `l4t-debs`
  mirror (see below).

### Past references consulted (not used in current builds)

Listed here because [`docs/tegra-x1-research.md`](docs/tegra-x1-research.md)
weighs them and they may come back if the Tegra X1 mainline story matures:

- `CTCaer/switch-l4t-kernel-4.9` (predecessor of NaGaa95's fork)
- `DigiJLinux/switch-l4t-kernel-6.1` (inactive 6.1 attempt)
- `hexdump0815/linux-mainline-tegra-x1-kernel`
- `grate-driver` (open-source Tegra DRM stack)
- The Switchroot wiki and the postmarketOS Nintendo Switch wiki for
  device-tree and userspace context.

---

## Emulators

All emulator builds clone the upstream tree on every CI run, apply
nothing but our compile flags (LTO, jemalloc, `-march=…`), and produce
a `.pkg.tar` keyed by upstream commit + our build hash.

| Emulator | Upstream | System |
|---|---|---|
| Azahar | [`azahar-emu/azahar`](https://github.com/azahar-emu/azahar) | Nintendo 3DS |
| Dolphin | [`dolphin-emu/dolphin`](https://github.com/dolphin-emu/dolphin) | GameCube / Wii / Wii U |
| DuckStation | [`stenzek/duckstation`](https://github.com/stenzek/duckstation) | PlayStation 1 |
| DuckStation deps | [`duckstation/dependencies`](https://github.com/duckstation/dependencies) | build prerequisites for DuckStation |
| melonDS | [`melonDS-emu/melonDS`](https://github.com/melonDS-emu/melonDS) | Nintendo DS |
| PPSSPP | [`hrydgard/ppsspp`](https://github.com/hrydgard/ppsspp) | PlayStation Portable |
| xemu | [`xemu-project/xemu`](https://github.com/xemu-project/xemu) | Original Xbox |
| EmulationStation Desktop Edition | [`es-de/emulationstation-de`](https://gitlab.com/es-de/emulationstation-de) | frontend / launcher |

Each carries its own license (Dolphin: GPL-2.0; PPSSPP: GPL-2.0;
DuckStation: GPL-3.0; melonDS: GPL-3.0; xemu: GPL-2.0; ES-DE: MIT;
Azahar: GPL-2.0). The upstream `LICENSE` file is retained inside the
binary package we ship.

---

## RetroArch and libretro cores

The libretro pipeline (`libretro-heavy-1/2/3` + `libretro-light` +
`libretro-package` aggregator) clones every core from the
[**libretro organisation**](https://github.com/libretro) at depth 1,
recursive — with one exception: `flycast` is cloned from
[`flyinghead/flycast`](https://github.com/flyinghead/flycast), the
upstream where active development happens (libretro/flycast is frozen
and explicitly redirects to the flyinghead repo). The full per-batch
list lives inside `emulators/libretro-*/build.sh`. Cores currently
packaged include (non-exhaustive):

- **Arcade / multi-system**: `mame2003-plus-libretro` (ROMset 0.78),
  `mame2010-libretro` (ROMset 0.139), `mame2016-libretro` (ROMset 0.174),
  `beetle-saturn-libretro`, `dosbox-pure`, `flycast` (Dreamcast, from
  flyinghead/flycast), `opera-libretro` (3DO), `neocd_libretro`,
  `geolith-libretro`.
- **Console**: `Genesis-Plus-GX`, `libretro-fceumm` (NES),
  `gambatte-libretro` (Game Boy / Color), `gpsp` (GBA),
  `beetle-pce-fast-libretro` (PC Engine),
  `beetle-supergrafx-libretro`, `beetle-vb-libretro` (Virtual Boy),
  `beetle-wswan-libretro` (WonderSwan), `virtualjaguar-libretro`,
  `libretro-handy` (Atari Lynx), `libretro-o2em` (Odyssey 2),
  `libretro-vecx` (Vectrex), `FreeChaF` (Channel F),
  `FreeIntv` (Intellivision).
- **Computer**: `vice-libretro` (C64), `blueMSX-libretro`, `PUAE`
  (Amiga), `fuse-libretro` (ZX Spectrum), `libretro-cap32` (CPC),
  `libretro-atari800`, `px68k-libretro` (X68000),
  `quasi88-libretro` (PC-88).

Each core keeps its upstream license (a mix of GPL-2.0, GPL-3.0,
LGPL, MAME's own license, and a few non-commercial licenses for
specific cores — we publish those separately or skip them per the
RetroArch policy). RetroArch itself is GPL-3.0.

---

## Performance libraries (rebuilt with our flags)

`perf-libs` rebuilds a fixed set of low-level libraries with LTO +
`-march=<target>` + jemalloc, then ships them as `<source_distro>-`
prefixed deps so emulators link against an optimised stack instead
of stock distro packages. Library list:

| Library | Upstream | Role | License |
|---|---|---|---|
| LLVM | [`llvm/llvm-project`](https://github.com/llvm/llvm-project) | runtime (`libllvm*`) | Apache-2.0 with LLVM-exception |
| libdrm | [`mesa/drm`](https://gitlab.freedesktop.org/mesa/drm) | DRI / DRM kernel interface | MIT |
| Mesa | [`mesa/mesa`](https://gitlab.freedesktop.org/mesa/mesa) | OpenGL / Vulkan / VAAPI drivers | MIT |
| Vulkan-Loader | [`KhronosGroup/Vulkan-Loader`](https://github.com/KhronosGroup/Vulkan-Loader) | Vulkan ICD loader | Apache-2.0 |
| libva | [`intel/libva`](https://github.com/intel/libva) | Video Acceleration API | MIT |
| Intel Media Driver | [`intel/media-driver`](https://github.com/intel/media-driver) | Intel iGPU encode/decode (x86 only) | MIT |
| jemalloc | [`jemalloc/jemalloc`](https://github.com/jemalloc/jemalloc) | allocator | BSD-2-Clause |
| SDL3 | [`libsdl-org/SDL`](https://github.com/libsdl-org/SDL) | windowing / input / audio | Zlib |
| zlib-ng | [`zlib-ng/zlib-ng`](https://github.com/zlib-ng/zlib-ng) | drop-in zlib replacement | Zlib |
| zstd | [`facebook/zstd`](https://github.com/facebook/zstd) | compression | BSD-3-Clause + GPL-2.0 (dual) |
| FFmpeg | [`FFmpeg/FFmpeg`](https://github.com/FFmpeg/FFmpeg) | codec library, built with `--enable-gpl --enable-version3 --enable-vaapi --enable-vulkan --enable-libdrm` | GPL-3.0 (in the configuration we ship) |

Mesa carries a small Turnip-tweak patch series for `arm64-modern` in
[`packages/perf-libs/packages/mesa/patches/`](packages/perf-libs/packages/mesa/patches/);
those patches retain their authors' `Signed-off-by` lines.

---

## External package mirrors

- [**`theofficialgman/l4t-debs`**](https://github.com/theofficialgman/l4t-debs)
  — the only third-party `.deb` mirror we resync, used to provide the
  Nintendo Switch L4T 32.7 stack (`nvidia-l4t-*`, `nvidia-bsp-*`,
  `cuda-cudart-*`, `switch-*`, `joycond`, `xserver-xorg-*`,
  `nintendo-switch-meta`). Filtered through the `include`/`exclude`
  globs on the `l4t` device entry in [`devices.yml`](devices.yml) — we
  drop the bundled chromium / yt-dlp / widevine / flatpak / plymouth
  themes / OSK / appstream / `-dev` / `-doc` / `-dbg` payloads since
  they're not part of an emulator runtime. Upstream license: per
  package — most NVIDIA L4T pieces are NVIDIA proprietary and shipped
  unmodified; everything else carries its own upstream license.

---

## Packaging and build tooling

The repo wraps a stack of distribution-native tooling that we shell
out to during the cross-distro convert step. Crediting them here
because without these we couldn't publish anything:

- **dpkg / dpkg-deb** (Debian) — `.deb` packing.
- **rpm / rpmbuild** (Fedora) — `.rpm` packing.
- **pacman / makepkg / repo-add** (Arch) — Pacman packaging and repo
  metadata.
- **createrepo_c** — DNF repository metadata.
- **reprepro / aptly** (when used) — APT repository metadata.
- **ccache** — compilation caching across CI runs.
- **CMake**, **Ninja**, **Meson** — build systems used by various
  upstream projects.
- **yq**, **jq** — YAML/JSON parsing in `compute-chains.sh`,
  `mirror-devices.yml` and friends.
- **dracut**, **update-initramfs**, **mkinitcpio** — distro-native
  initramfs generators called from our kernel `postinst` hooks.

---

## CI infrastructure

The pipeline runs entirely on GitHub Actions and uses these
first-party actions (no third-party actions are pulled — the surface
area is intentionally small):

| Action | Version | Purpose |
|---|---|---|
| `actions/checkout` | v4 | clone the repo into the runner |
| `actions/cache` (+ `restore`/`save`) | v4 | ccache + intermediate artifacts |
| `actions/upload-artifact` | v4 | publish built `.pkg.tar` files |
| `actions/download-artifact` | v4 | aggregator + chain dependency fetch |
| `actions/upload-pages-artifact` | v3 | gh-pages staging |
| `actions/deploy-pages` | v4 | GitHub Pages deploy |
| `actions/github-script` | v7 | inline GitHub API scripting |

Build runner base image: [`ubuntu:26.04`](https://hub.docker.com/_/ubuntu)
extended with the kernel build toolchain (cache key `emu-deps-base-v7`).

---

## Reporting an attribution issue

If you maintain a project listed above and the credit / license note
is wrong or incomplete, open an issue or PR — we'll fix it. We try to
be careful but this list is large and upstream licenses change.
