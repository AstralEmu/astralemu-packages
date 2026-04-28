# kernel-amd64

Custom Linux kernel for AstralEmu x86_64 handheld devices (Steam Deck,
ROG Ally, Legion Go, MSI Claw, GPD Win, AYANEO, AYN Loki, …).

## Sources

| Component | Source |
|---|---|
| Linux base | `git.kernel.org/.../stable/linux.git` (LTS pinned in `config/kernel-version`) |
| BORE scheduler | `firelzrd/bore-scheduler` |
| CachyOS portable + handheld patches | `CachyOS/kernel-patches` (filtered cherry-picks) |
| Valve handheld patches | `ValveSoftware/linux-integration` (filtered cherry-picks) |

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
   `.pkg.tar` (kernel + sub-packages `kernel-modules-amd64`,
   `astralemu-firmware-amd-handheld`).

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
    cachyos/                              ditto
    handheld-extras/                      ditto (Valve + extras)

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
relevant `Based on:` notes for Valve and CachyOS are emitted by
`build.sh` into `meta/description`.
