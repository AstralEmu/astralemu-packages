<p align="center">
  <img src="https://github.com/AstralEmu/.github/raw/refs/heads/main/profile/banner-astralemu.svg" alt="AstralEmu Packages" width="100%"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/rebuilt-every%2024h-f2d974?style=flat-square" alt="Daily rebuild"/>
  <img src="https://img.shields.io/badge/LTO-thin-1a1a4e?style=flat-square" alt="LTO"/>
  <img src="https://img.shields.io/badge/allocator-jemalloc-1a1a4e?style=flat-square" alt="jemalloc"/>
</p>

# AstralEmu Packages

Optimized emulator packages for AstralEmu, rebuilt daily from source with performance flags and architecture-specific compilation.

This repository serves packages through **APT**, **DNF**, and **Pacman** — matching whichever base distro your AstralEmu image uses.

---

## What's included

### Emulators (standalone)

Every major standalone emulator is packaged and rebuilt daily. Examples include RetroArch, PPSSPP, Dolphin, PCSX2, Duckstation, Citra, Yuzu/Suyu, RPCS3, AetherSX2, and more — the full list depends on what's supported on your target architecture.

### RetroArch Cores

All RetroArch cores are built individually as separate packages, so you only install what you need.

### Hardware Dependencies

Device-specific packages that provide kernel modules, firmware, and drivers required by embedded targets (RK3588, Snapdragon, Amlogic, etc.).

### Performance Profiles

Per-device packages that contain the dynamic tuning rules for the [Performance Manager](https://github.com/AstralEmu/astralemu#performance-manager) — CPU/GPU/RAM governors, clocks, and pinning configs for every supported emulator.

---

## Build optimizations

Every package is compiled with:

| Flag | Purpose |
|---|---|
| `LTO=thin` | Link-time optimization — reduces binary size and improves runtime performance |
| `jemalloc` | Replaces glibc's allocator for lower fragmentation and better throughput |
| Architecture targeting | Packages are compiled for the exact CPU features of each device (NEON, SVE, SSE4, AVX2, etc.) |

Builds run on GitHub Actions and are triggered automatically every 24 hours, or on-demand when a new emulator release is tagged upstream.

## Repository setup

### APT (Ubuntu / Debian)

```bash
curl -fsSL https://astralemu.github.io/repo/astralemu.gpg | sudo tee /usr/share/keyrings/astralemu.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/astralemu.gpg] https://astralemu.github.io/repo/apt stable main" | sudo tee /etc/apt/sources.list.d/astralemu.list
sudo apt update
```

### DNF (Universal Blue / Fedora)

```bash
sudo dnf config-manager --add-repo https://astralemu.github.io/repo/dnf/astralemu.repo
```

### Pacman (Arch Linux)

Add to `/etc/pacman.conf`:
```ini
[astralemu]
SigLevel = Optional TrustAll
Server = https://astralemu.github.io/repo/pacman/$arch
```

> **Note**: These are placeholder URLs. Update them to match your actual deployment.

## Build matrix

The CI dynamically generates the build matrix based on:

- **Target architecture** — ARM64, x86_64, and device-specific variants
- **Package manager** — Generates `.deb`, `.rpm`, and Pacman packages from the same source
- **Upstream version** — Tracks upstream releases and rebuilds on new tags

---

<p align="center">
  <a href="https://github.com/AstralEmu/astralemu">Main Repo</a> •
  <a href="https://astralemu.github.io">Documentation</a> •
  <a href="https://github.com/orgs/AstralEmu/discussions">Community</a>
</p>
