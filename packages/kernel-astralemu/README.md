# kernel-astralemu

Per-device meta-package that bundles every device-specific piece of the
AstralEmu kernel stack into a single `apt install` / `dnf install` /
`pacman -S` command.

## What it pulls in

For a given hardware device `<device>`, `kernel-astralemu-<device>`
depends on:

| Dep | Source |
|---|---|
| `kernel-<flavor>` | `kernel-amd64` / `kernel-arm64-modern` / `kernel-arm64-legacy` / `kernel-tegra-x1` (Switch) |
| `kernel-modules-<flavor>` | matching modules sub-package |
| `astralemu-dtbs-<flavor>` | matching DTB sub-package (ARM only) |
| `setperf` | per-device performance tuning |
| `astralemu-deps-repo` | repo configuration package |
| `astralemu-firmware-<vendor>` | optional, mapped per-device by `firmware_for_device()` in `build.sh` |

The "flavor" is normally the device's `build_target` (so all
arm64-legacy handhelds share `kernel-arm64-legacy`), with one
exception: the Nintendo Switch (`l4t`) maps to `kernel-tegra-x1`
because mainline 6.x can't drive its GPU.

## Why

End-user UX. Without this:

```bash
sudo apt install kernel-arm64-legacy kernel-modules-arm64-legacy \
                 astralemu-dtbs-arm64-legacy astralemu-firmware-tegra \
                 setperf astralemu-deps-repo
```

With this:

```bash
sudo apt install kernel-astralemu-l4t
```

## How it builds

`per_device: true` in [packages.yml](../../packages.yml) makes the
build iterate over each device. The build script is a no-op tarball:
empty `root/`, only `meta/depends`. `arch = all` (it's a virtual
package, no binaries).

`build.sh` reads `devices.yml` to discover each device's build_target
and emits the matching depends list. Vendor firmware deps are mapped
inline by the `firmware_for_device()` case statement at the top of
`build.sh` (a device with no entry simply gets no vendor firmware
dep). The map is inline rather than in a `templates/` subdir because
the build pipeline filters per_device packages on subdirectory
presence — see `scripts/compute-chains.sh`.

## Adding a device

1. Add the device in [devices.yml](../../devices.yml).
2. If it needs vendor firmware, add a `<device_id>) echo "astralemu-firmware-<vendor>" ;;`
   line to `firmware_for_device()` in `build.sh`.
3. Commit. The CI picks up the new device on its next run.

## Versioning

`hash-only`: `1.0.0+<short_hash>`. The hash bumps whenever the build
inputs change, forcing a republish so dependency updates propagate.
