<p align="center">
  <img src="https://github.com/AstralEmu/.github/raw/refs/heads/main/profile/banner-astralemu.svg" alt="AstralEmu Packages" width="100%"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/rebuilt-every%207%20day-f2d974?style=flat-square" alt="Weekly rebuild"/>
  <img src="https://img.shields.io/badge/LTO-thin-1a1a4e?style=flat-square" alt="LTO"/>
  <img src="https://img.shields.io/badge/allocator-jemalloc-1a1a4e?style=flat-square" alt="jemalloc"/>
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"/>
</p>

# AstralEmu Packages

Optimized emulator packages for AstralEmu, rebuilt daily from source with performance flags and architecture-specific compilation.

This repository serves packages through **APT**, **DNF**, and **Pacman** — matching whichever base distro your AstralEmu image uses. The repo is hosted via GitHub Pages at `https://astralemu.github.io/astralemu-packages/`.

---

## What's included

### Emulators (standalone)

Every major standalone emulator is packaged and rebuilt daily. Examples include RetroArch, PPSSPP, Dolphin, PCSX2, Duckstation, Azahar, Ryujinx, Eden, RPCS3, AetherSX2, and more — the full list depends on what's supported on your target architecture.

### RetroArch Cores

All RetroArch cores are built individually as separate packages, so you only install what you need.

### Hardware Dependencies

Device-specific packages that provide kernel modules, firmware, and drivers required by embedded targets (RK3588, Snapdragon, Amlogic, etc.).

### Custom kernels

Four kernel flavors covering every supported handheld, with BORE scheduler + CachyOS portable patches + per-SoC downstream cherry-picks (ROCKNIX) where relevant:

| Kernel | Devices | Source |
|---|---|---|
| `kernel-amd64` | Steam Deck, ROG Ally, Legion Go, MSI Claw, GPD Win, AYANEO, OneXPlayer, AYN Loki | Linux stable + BORE + CachyOS portable patches + the CachyOS handheld driver patch (Steam Deck hwmon/LEDs, ROG Ally / Legion Go / MSI Claw / Zotac Zone HID drivers, AMDGPU display quirks, AW87xxx audio codec) |
| `kernel-arm64-modern` | Retroid Pocket 5/6, AYN Thor, Orange Pi 5 (RK3588), generic Snapdragon 845-X3 | Linux stable + BORE + CachyOS portable + ROCKNIX SoC patches (qcom, rockchip, samsung) |
| `kernel-arm64-legacy` | Anbernic RG35XX H/SP/Plus + original, RG ARC, RG406, Powkiddy V90/X55, Odroid Go Super, Raspberry Pi 4 | Linux stable + BORE + CachyOS portable + ROCKNIX SoC patches (rockchip, amlogic, sunxi) |
| `kernel-tegra-x1` | Nintendo Switch only | NaGaa95/switch-l4t-kernel-4.9 (only actively maintained 4.9 fork; mainline 6.x can't drive Tegra X1's nvgpu) |

The build is split into 5 sub-jobs (`prep` → `image` + `modules-soc/platform` + `modules-generic` → aggregator) for the three modern kernels so that no single job comes near the GitHub Actions 6h ceiling. The Switch is a mono-job since the 4.9 tree builds in roughly an hour. A per-device meta-package `kernel-astralemu-<device>` pulls in the right kernel flavor + modules + dtbs (ARM only) + setperf + repo config in a single command.

### Performance Profiles

Per-device packages that contain the dynamic tuning rules for the [Performance Manager](https://github.com/AstralEmu/astralemu#performance-manager) — CPU/GPU/RAM governors, clocks, and pinning configs for every supported emulator.

---

## Build optimizations

Every package is compiled with:


| Flag                   | Purpose                                                                                       |
| ---------------------- | --------------------------------------------------------------------------------------------- |
| `LTO=thin`             | Link-time optimization — reduces binary size and improves runtime performance                |
| `jemalloc`             | Replaces glibc's allocator for lower fragmentation and better throughput                      |
| Architecture targeting | Packages are compiled for the exact CPU features of each device (NEON, SVE, SSE4, AVX2, etc.) |

Builds run on GitHub Actions and are triggered automatically every 24 hours, or on-demand when a new emulator release is tagged upstream.

## Repository setup

Each device has its own repository for emulator packages, plus a shared repository for dependencies grouped by source distribution. Replace `<device>` with your device ID (e.g. `l4t`) and `<source_distro>` with the source distribution (e.g. `ubuntu-lts`).

The `astralemu-deps-repo` meta-package (included in the device repo) automatically configures the shared dependency repository.

### APT (Ubuntu / Debian)

```bash
curl -fsSL https://astralemu.github.io/astralemu-packages/apt/device/<device>/astralemu.gpg | sudo tee /usr/share/keyrings/astralemu.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/astralemu.gpg] https://astralemu.github.io/astralemu-packages/apt/device/<device> $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/astralemu.list
sudo apt update
```

### DNF (Universal Blue / Fedora)

```bash
sudo dnf config-manager --add-repo https://astralemu.github.io/astralemu-packages/dnf/device/<device>/astralemu-<device>.repo
```

### Pacman (Arch Linux)

Add to `/etc/pacman.conf`:

```ini
[astralemu]
SigLevel = Optional TrustAll
Server = https://astralemu.github.io/astralemu-packages/pacman/device/<device>/$arch
```

### Available devices

The full list lives in [devices.yml](devices.yml). All devices currently share `ubuntu-lts` as their source distro — a rolling alias that always points to the latest Ubuntu LTS via the `ubuntu:latest` Docker base image. Pick the entry that best matches your hardware — generic baselines (`x86-v3`, `armv8-2`, …) are a fine fallback when your exact handheld isn't named yet.

ARM handhelds:

| Device ID | Hardware | build_target |
|---|---|---|
| `l4t` | Nintendo Switch (Tegra X1) | arm64-legacy + dedicated `kernel-tegra-x1` |
| `rpi4` | Raspberry Pi 4 | arm64-legacy |
| `anbernic-rg35xx-orig` | Anbernic RG35XX original (RK3326) | arm64-legacy |
| `anbernic-rg35xx-h` | Anbernic RG35XX H/SP/Plus (H700) | arm64-legacy |
| `powkiddy-rk3566` | Powkiddy V90 / X55 | arm64-legacy |
| `anbernic-rg406` | Anbernic RG406 series (RK3576) | arm64-legacy |
| `anbernic-rg-arc` | Anbernic RG ARC (S922X) | arm64-legacy |
| `odroid-go-super` | Odroid Go Super (S922X) | arm64-legacy |
| `retroid-pocket-5` | Retroid Pocket 5 (SM8250) | arm64-modern |
| `orange-pi-5` | Orange Pi 5 / Rock 5 (RK3588) | arm64-modern |
| `retroid-pocket-6` | Retroid Pocket 6 (SM8550) | arm64-modern |
| `ayn-thor` | AYN Thor (SM8550) | arm64-modern |
| `armv8-2`, `armv9` | generic ARMv8.2-A / ARMv9.0-A baselines | arm64-modern |

AMD/Intel handhelds:

| Device ID | Hardware | build_target |
|---|---|---|
| `ayn-loki` | AYN Loki / Loki Zero (Mendocino Zen 2) | amd64 |
| `steam-deck-lcd` | Steam Deck LCD (Van Gogh Zen 2) | amd64 |
| `steam-deck-oled` | Steam Deck OLED (Sephiroth Zen 2) | amd64 |
| `gpd-win` | GPD Win Mini / Max (Phoenix Z1 Zen 4) | amd64 |
| `rog-ally` | ASUS ROG Ally / Ally X (Phoenix Z1E Zen 4) | amd64 |
| `legion-go` | Lenovo Legion Go / Legion Go S (Phoenix Z1E) | amd64 |
| `msi-claw` | MSI Claw (Meteor Lake) | amd64 |
| `ayaneo` | AYANEO Geek/Slide/Kun (Phoenix / Hawk Point) | amd64 |
| `onexplayer` | OneXPlayer X1 / OneXFly (Phoenix / Strix Point) | amd64 |
| `x86-v2`, `x86-v3`, `x86-v4` | generic x86-64-v2/v3/v4 baselines | amd64 |

## Hosting

This repo has its own GitHub Pages enabled. The built packages and repo metadata are served as static files from the `gh-pages` branch:

```
https://astralemu.github.io/astralemu-packages/
├── apt/device/<device>/pool/<distro>/       # emulator packages
├── apt/device/<device>/dists/<distro>/
├── apt/deps/<source_distro>/pool/<distro>/  # shared dependencies
├── apt/deps/<source_distro>/dists/<distro>/
├── dnf/device/<device>/<version>/<arch>/
├── dnf/deps/<source_distro>/<version>/<arch>/
├── pacman/device/<device>/<arch>/
└── pacman/deps/<source_distro>/<arch>/
```

The CI pipeline builds the packages on `main`, then pushes the repo metadata and package files to `gh-pages` for serving.

## Build matrix

The CI dynamically generates the build matrix from two config files:

- **`devices.yml`** — Target devices with architecture, compiler flags, and package sources to mirror
- **`distros.yml`** — Target distributions (APT, DNF, Pacman) with their versions and mirrors

Every package is cross-built to all target formats (`.deb`, `.rpm`, Pacman) with automatic dependency resolution. Dependencies missing or incompatible on the target distro are fetched from the source distribution, prefixed with its source-distro id (e.g. `ubuntu-lts-libfoo`), and published to a shared dependency repository. Devices with the same source distribution share the same dependencies.

---

## Credits

This repository builds and mirrors a lot of other people's work — the Linux kernel, the BORE scheduler, CachyOS portable + handheld patches, ROCKNIX's per-SoC downstream patch series, NaGaa95's Switch 4.9 fork, every emulator and libretro core listed above, the perf-libs stack (Mesa, Vulkan-Loader, FFmpeg, jemalloc, SDL3, …) and `theofficialgman/l4t-debs`. The full list with upstream URLs and license notes lives in [CREDITS.md](CREDITS.md). If you find a missing or incorrect attribution, open an issue.

---

<p align="center">
  <a href="https://github.com/AstralEmu/astralemu">Main Repo</a> •
  <a href="https://astralemu.github.io">Documentation</a> •
  <a href="https://github.com/orgs/AstralEmu/discussions">Community</a>
</p>
