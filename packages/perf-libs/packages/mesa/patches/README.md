# Turnip (freedreno) patches

Optional patches to the Mesa Turnip Vulkan driver, cherry-picked from
[Weab-chan/freedreno_turnip-CI](https://github.com/Weab-chan/freedreno_turnip-CI).
Applied only when `TARGET_ID=arm64-modern` (the target that covers
Snapdragon 845+, including 8 Gen 1/2/3).

Turnip is the Vulkan driver for Adreno GPUs. It is only selected at runtime
when a Qualcomm Adreno GPU is detected, so these patches are inert on the
other devices sharing `arm64-modern` (Raspberry Pi 5 uses v3d, RK3588 uses
panfrost). Same binary ships everywhere.

## Included

| File | Purpose |
| ---- | ------- |
| `8g2_ui_glitch.patch` | Enable `tp_ubwc_flag_hint` on 8 Gen 2 to fix a UI glitch |
| `a7xx_gen1_random_stuff.patch` | Scheduler tweaks for a7xx gen1 (8 Gen 1/2) |
| `fix_a725_a730.patch` | Add `compute_constlen_quirk` for a725/a730 |
| `quest3.patch` | Add Meta Quest 3 (XR2 Gen 2) GPU id + props |

## Deliberately excluded

From the same upstream, dropped because they degrade general gaming:

| File | Why excluded |
| ---- | ------------ |
| `disable_KHR_workgroup_memory_explicit_layout.patch` | Disables a Vulkan extension games may require |
| `disable_has_branch_and_or.patch` | Shader workaround for one specific emulator |
| `force_sysmem_no_autotuner.patch` | Forces sysmem path — helps Android emus, hurts Proton/Steam |

## Updating

Patches are written against specific Mesa revisions and bitrot when Mesa
refactors the freedreno sources. When a patch stops applying:

1. Pull the latest version from
   [Weab-chan/freedreno_turnip-CI/patches/](https://github.com/Weab-chan/freedreno_turnip-CI/tree/main/patches)
2. Replace the file here
3. If the patch has been accepted upstream Mesa (unlikely for quirks but
   possible for `quest3` / device id additions), drop it entirely

`build.sh` applies patches with `git apply --check` first — a rejected
patch fails the build so drift is caught immediately.
