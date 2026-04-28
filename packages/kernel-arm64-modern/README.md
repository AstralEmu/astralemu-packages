# kernel-arm64-modern

Custom Linux kernel for armv8.2-a+dotprod handhelds: AYN Thor / Retroid
Pocket 6 (sm8550), Retroid Pocket 5 (sm8250), Snapdragon 8 Gen 1/2/3
handhelds (sm8550, sm8650), Orange Pi 5 / Rock 5 (rk3588), Anbernic
RG406 (rk3576), entry-level Snapdragon (sm6115).

## Sources

| Component | Source |
|---|---|
| Linux base | `cdn.kernel.org/.../linux-<KVER>.tar.xz` (KVER pinned by ROCKNIX `package.mk`) |
| BORE scheduler | `firelzrd/bore-scheduler` matching v<KVER major.minor> |
| CachyOS portable patches | `CachyOS/kernel-patches`, x86-only patches filtered out |
| Adreno (sm6115/sm8250/sm8550/sm8650) | ROCKNIX `projects/ROCKNIX/devices/SM*/patches/` |
| Mali-G610 (rk3588), Rockchip Panthor / RK3576 | ROCKNIX `projects/ROCKNIX/devices/RK35**/patches/` |
| DTBs | ROCKNIX `projects/ROCKNIX/devices/<SoC>/linux/dts/` |

ROCKNIX patches are pulled by `scripts/sync-rocknix-kernels.sh` into
`packages/kernel-arm64-modern/patches/soc-downstream/<SoC>/`.

## Build split

Five sub-jobs (cf. `docs/kernel-integration-plan.md`), each well below
the 6h GH Actions limit. The split mirrors `kernel-amd64` but
`modules-soc` collects the ROCKNIX-relevant SoC drivers (drivers/gpu/drm/
{msm,panthor,rockchip,panfrost}, drivers/soc/{qcom,rockchip,…}, drivers/
clk/qcom, drivers/clk/rockchip, …).

Sub-job ids: `kernel-arm64-modern-{prep,image,modules-soc,modules-generic}`
plus the aggregator `kernel-arm64-modern`.

## Licensing

GPL v2. ROCKNIX cherry-picks retain their `Signed-off-by:` and source
URLs are recorded in `meta/description` of the produced packages.
