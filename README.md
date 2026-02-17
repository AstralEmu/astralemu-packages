<p align="center">
  <img src="https://github.com/AstralEmu/.github/raw/refs/heads/main/profile/banner-astralemu.svg" alt="AstralEmu Packages" width="100%"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/rebuilt-every%2024h-f2d974?style=flat-square" alt="Daily rebuild"/>
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

Each device has its own repository. Replace `<device>` with your device ID (e.g. `l4t` for Nintendo Switch).

### APT (Ubuntu / Debian)

```bash
curl -fsSL https://astralemu.github.io/astralemu-packages/apt/<device>/astralemu.gpg | sudo tee /usr/share/keyrings/astralemu.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/astralemu.gpg] https://astralemu.github.io/astralemu-packages/apt/<device> $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/astralemu.list
sudo apt update
```

### DNF (Universal Blue / Fedora)

```bash
sudo dnf config-manager --add-repo https://astralemu.github.io/astralemu-packages/dnf/<device>/astralemu-<device>.repo
```

### Pacman (Arch Linux)

Add to `/etc/pacman.conf`:

```ini
[astralemu]
SigLevel = Optional TrustAll
Server = https://astralemu.github.io/astralemu-packages/pacman/<device>/$arch
```

### Available devices

| Device ID | Name | Architecture |
| --------- | ---- | ------------ |
| `l4t` | Nintendo Switch (Tegra X1) | arm64 |

## Hosting

This repo has its own GitHub Pages enabled. The built packages and repo metadata are served as static files from the `gh-pages` branch, with per-device repositories:

```
https://astralemu.github.io/astralemu-packages/
├── apt/<device>/pool/<distro>/
├── apt/<device>/dists/<distro>/
├── dnf/<device>/<version>/<arch>/
└── pacman/<device>/<arch>/
```

The CI pipeline builds the packages on `main`, then pushes the repo metadata and package files to `gh-pages` for serving.

## Build matrix

The CI dynamically generates the build matrix from two config files:

- **`devices.yml`** — Target devices with architecture, compiler flags, and package sources to mirror
- **`distros.yml`** — Target distributions (APT, DNF, Pacman) with their versions and mirrors

Every package is cross-built to all target formats (`.deb`, `.rpm`, Pacman) with automatic dependency resolution. Dependencies missing or incompatible on the target distro are fetched from source, prefixed with the device ID (e.g. `l4t-libfoo`), and included in the device repo.

---

<p align="center">
  <a href="https://github.com/AstralEmu/astralemu">Main Repo</a> •
  <a href="https://astralemu.github.io">Documentation</a> •
  <a href="https://github.com/orgs/AstralEmu/discussions">Community</a>
</p>
