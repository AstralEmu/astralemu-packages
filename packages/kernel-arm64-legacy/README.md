# kernel-arm64-legacy

Custom Linux kernel for armv8-a Cortex-A53/A55/A57/A72/A73 handhelds:
Anbernic RG35XX series (H700), RG ARC and Odroid Go Super (S922X),
Powkiddy V90/X55 (RK3566), original Anbernic RG35XX (RK3326), Pinebook
(RK3399).

## Sources

| Component | Source |
|---|---|
| Linux base | `cdn.kernel.org/.../linux-<KVER>.tar.xz` (KVER pinned by ROCKNIX `package.mk`) |
| BORE scheduler | `firelzrd/bore-scheduler` matching v<KVER major.minor> |
| CachyOS portable patches | `CachyOS/kernel-patches`, x86-only patches filtered out |
| H700 (Allwinner) | ROCKNIX `projects/ROCKNIX/devices/H700/patches/` |
| RK3326 / RK3399 / RK3566 (Rockchip) | ROCKNIX `projects/ROCKNIX/devices/RK33*/patches/` |
| S922X (Amlogic) | ROCKNIX `projects/ROCKNIX/devices/S922X/patches/` |
| DTBs | ROCKNIX `projects/ROCKNIX/devices/<SoC>/linux/dts/` |

ROCKNIX patches are pulled by `scripts/sync-rocknix-kernels.sh` into
`packages/kernel-arm64-legacy/patches/soc-downstream/<SoC>/`.

## Devices NOT covered here

The Nintendo Switch (Tegra X1) is on its own kernel target,
`kernel-tegra-x1`, sourced from `NaGaa95/switch-l4t-kernel-4.9` because
the L4T 32.x downstream stack is incompatible with mainline 6.x. See
`docs/tegra-x1-research.md` for the rationale.

## Build split

Five sub-jobs (cf. `docs/kernel-integration-plan.md`). modules-soc
keeps `drivers/gpu/drm/{rockchip,panfrost,lima,meson}` plus
`drivers/{soc,clk,pinctrl}/{rockchip,amlogic,sunxi}`. modules-generic
takes the complement.

Sub-job ids: `kernel-arm64-legacy-{prep,image,modules-soc,modules-generic}`
plus the aggregator `kernel-arm64-legacy`.

## Licensing

GPL v2. ROCKNIX cherry-picks retain their `Signed-off-by:` lines.
