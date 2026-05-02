# kernel-amd64

Custom Linux kernel for AstralEmu x86_64 handheld devices (Steam Deck,
ROG Ally, Legion Go, MSI Claw, GPD Win, AYANEO, AYN Loki, …).

## Sources

| Component | Source |
|---|---|
| Linux base | `cdn.kernel.org/pub/linux/kernel/v<X>.x/linux-<KVER>.tar.xz` (KVER pinned dynamically from ROCKNIX `package.mk`) |
| BORE scheduler | [`firelzrd/bore-scheduler`](https://github.com/firelzrd/bore-scheduler) |
| CachyOS portable patches | [`CachyOS/kernel-patches`](https://github.com/CachyOS/kernel-patches) — `<X.Y>/*.patch` (scheduler / MM / x86 perf tweaks) |
| CachyOS handheld driver patch | `CachyOS/kernel-patches` — `<X.Y>/misc/0001-handheld.patch` (Steam Deck hwmon/LEDs/extcon/mfd, ROG Ally, Legion Go, MSI Claw, Zotac Zone, AMDGPU display quirks, AW87xxx audio codec) |

**Why no Valve `linux-integration`** — the upstream `ValveSoftware/linux-integration` GitHub repo was deleted (the older `ValveSoftware/linux` is a 2017-era SteamOS 2 / Debian fork, unrelated). The current SteamOS 3 source mirror lives on the Holo `gitlab.steamos.cloud/jupiter/linux-integration.git` GitLab instance which requires authenticated access — not viable for an unattended CI clone. The two unique kernel features Valve still ships (AMD P-State EPP handheld profile, NTSYNC sync primitive) are **upstream as of 6.18-6.19**, so we don't lose anything functional by dropping the Valve source.

## Build split

Five sub-jobs orchestrated by the AstralEmu aggregator pattern,
each well under the 6h GH Actions limit (cf. `docs/kernel-integration-plan.md`):

1. `kernel-amd64-prep` — clone source, apply patches, savedefconfig,
   tarball → artifact `kernel-prep-…`
2. `kernel-amd64-image` — extract prep, `make bzImage`,
   System.map/config → artifact `kernel-image-…`
3. `kernel-amd64-modules-platform` — `make modules`, keep only
   AMD/Intel platform/GPU/firmware drivers → artifact `kernel-modules-…-platform`
4. `kernel-amd64-modules-generic` — `make modules`, keep everything
   else (net, usb, hid, sound, fs, crypto, …) → artifact
   `kernel-modules-…-generic`
5. `kernel-amd64` (aggregator) — pull all four artifacts, merge into
   `.pkg.tar` (kernel + sub-package `kernel-modules-amd64`).
   `astralemu-firmware-amd-handheld` is referenced from `kernel-astralemu`
   but the firmware package itself is not yet built — see the firmware
   epic note in `docs/kernel-integration-plan.md`.

## Layout

```
packages/kernel-amd64/                    ← aggregator + shared assets
  build.sh                                aggregator (downloads sub-job artifacts)
  README.md
  config/
    kernel-version                        e.g. "6.12.4"
    defconfig                             our overrides on top of x86_64_defconfig
  patches/
    bore/                                 fetched at build time
    cachyos/                              ditto (portable + misc/handheld)
    handheld-extras/                      project-specific tweaks (vendored)

packages/kernel-amd64-prep/
  build.sh                                clone + patch + savedefconfig
packages/kernel-amd64-image/
  build.sh                                make bzImage
packages/kernel-amd64-modules-platform/
  build.sh                                AMD/Intel/GPU/firmware modules
packages/kernel-amd64-modules-generic/
  build.sh                                everything else
```

The four sub-job dirs source `packages/kernel-amd64/lib/common.sh`
for the patch URLs / kernel version pin / shared helpers, so the
sub-builds stay short.

## Licensing

GPL v2. Patches retain their original `Signed-off-by:` lines.
ROCKNIX is not used here (x86 isn't covered by ROCKNIX); the
relevant `Based on:` notes for BORE and CachyOS are emitted by
`build.sh` into `meta/description`.
