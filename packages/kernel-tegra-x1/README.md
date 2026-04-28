# kernel-tegra-x1

Linux 4.9 kernel for the Nintendo Switch (Tegra X1, T210 / T210B01).

## Why a separate target

Tegra X1 is the only handheld in our scope where mainline 6.x doesn't
provide a working stack: NVIDIA's `nvgpu` driver (Maxwell GM20B 3D)
isn't upstream and was never ported to >= 5.x for T210 (NVIDIA EOL'd
the Jetson Nano). Mainline + nouveau boots but delivers ~10–30% of the
GPU performance — insufficient for PSP/N64-class emulation. BORE and
CachyOS patches don't apply on 4.9 (different scheduler/mm internals),
so they are deliberately not used here.

The full ecosystem analysis lives in `docs/tegra-x1-research.md`,
including the deferred PoC plan to revisit a mainline 6.x port later.

## Sources

| Component | Source |
|---|---|
| Kernel source | [`NaGaa95/switch-l4t-kernel-4.9`](https://github.com/NaGaa95/switch-l4t-kernel-4.9) (only actively maintained 4.9 fork, 2026-04 commits adding `erista` support) |
| Userspace `nvidia-l4t-*` / `switch-*` / xorg / joycond | filtered mirror of [`theofficialgman/l4t-debs`](https://github.com/theofficialgman/l4t-debs) — see the whitelist in `devices.yml` sources for `l4t` |

The mirror filter excludes packages that are not Switch-hardware
specific (`chromium-browser`, `switch-flatpak`, `yt-dlp`,
`libwidevinecmd0`).

## Build shape

Mono-job (no split): the 4.9 kernel + a small set of in-tree modules
compiles in roughly 1 h on a native arm64 runner, well below the GH
Actions 6 h ceiling. Everything happens in one `build.sh`:

1. Clone `NaGaa95/switch-l4t-kernel-4.9` (branch `linux-dev`)
2. Apply Switch tegra defconfig (`tegra_linux_defconfig`-like)
3. `make Image dtbs modules` (single shot)
4. `make modules_install INSTALL_MOD_STRIP=1`
5. Stage `boot/{vmlinuz,System.map,config}`,
   `lib/modules/<ver>/`, `usr/lib/linux-image-<ver>/dtbs/`
6. Emit `meta/scripts/postinst` (generic update-initramfs / dracut /
   mkinitcpio detector — same as the other kernels)
7. Tar three packages: `kernel-tegra-x1`, `kernel-modules-tegra-x1`,
   `astralemu-dtbs-tegra-x1`

`per_device: true` + `target_filter: [l4t]` ensures this only runs
for the Switch device, not for the rest of `arm64-legacy`.

## Licensing

GPL v2. Carries upstream NVIDIA L4T patches via NaGaa95 (each retains
its `Signed-off-by:`). nvgpu binary blob is not redistributed by us —
the user gets it via the filtered userspace mirror.
