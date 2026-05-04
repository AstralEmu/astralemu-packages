# kernel-amd64

Custom Linux kernel for AstralEmu x86_64 handheld devices (Steam Deck,
ROG Ally, Legion Go, MSI Claw, GPD Win, AYANEO, AYN Loki, …).

## Sources

| Component | Source |
|---|---|
| Kernel source | [`CachyOS/linux`](https://github.com/CachyOS/linux) `<X.Y>/cachy` branch (auto-detected latest) — includes BORE scheduler, handheld drivers, amd-pstate, fixes, and all CachyOS patches pre-merged |
| Local extras | `packages/kernel-amd64/patches/handheld-extras/*.patch` (project-specific overrides, currently empty) |

**Why CachyOS/linux instead of mainline + patches** — CachyOS maintains a full
kernel source tree on `<X.Y>/cachy` branches that already includes their
scheduler, handheld driver, and performance patches merged together. Trying
to apply individual patches from CachyOS/kernel-patches onto vanilla mainline
breaks whenever their patches reference CachyOS-internal kernel APIs (e.g.
`hdev->firmware_version`, `hdev->uevent` in `struct hid_device` in 6.15.x).
Cloning the pre-merged tree eliminates all patch compatibility issues.

**Why no Valve `linux-integration`** — the upstream `ValveSoftware/linux-integration`
GitHub repo was deleted (the older `ValveSoftware/linux` is a 2017-era
SteamOS 2 / Debian fork, unrelated). The current SteamOS 3 source mirror lives
on the Holo `gitlab.steamos.cloud/jupiter/linux-integration.git` GitLab
instance which requires authenticated access — not viable for an unattended CI
clone. The two unique kernel features Valve still ships (AMD P-State EPP
handheld profile, NTSYNC) are **upstream as of 6.18-6.19**, so we don't lose
anything functional by dropping the Valve source. CachyOS already includes
handheld driver support from their own tree.

## Build split

Five sub-jobs orchestrated by the AstralEmu aggregator pattern,
each well under the 6h GH Actions limit (cf. `docs/kernel-integration-plan.md`):

1. `kernel-amd64-prep` — clone CachyOS kernel source, apply local extras
   (if any), `x86_64_defconfig` + config fragment merge, tarball
   → artifact `kernel-prep-…`
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
    defconfig.fragment                    our overrides on top of x86_64_defconfig
  patches/
    handheld-extras/                      project-specific tweaks (vendored, currently empty)

packages/kernel-amd64-prep/
  build.sh                                clone + configure + tarball
packages/kernel-amd64-image/
  build.sh                                make bzImage
packages/kernel-amd64-modules-platform/
  build.sh                                AMD/Intel/GPU/firmware modules
packages/kernel-amd64-modules-generic/
  build.sh                                everything else
```

## Licensing

GPL v2. The CachyOS kernel source retains their original `Signed-off-by:`
lines. BORE scheduler patches are from `firelzrd/bore-scheduler` (GPL v2).