#!/bin/bash
# emit-aliases.sh — Append Provides/Replaces aliases for every hardware device
# that maps to the current build_target.
#
# Usage: emit-aliases.sh <package_basename> <meta_dir>
#
# Env:
#   TARGET_DEVICES — comma-separated device ids sharing the current build_target
#                    (set by build-chain.yml from devices.yml). Empty/unset
#                    for per_device packages — then this is a no-op.
#
# Behavior:
#   For each <device>, writes "<basename>-<device>" to provides+replaces so
#   legacy device-named packages (e.g. azahar-emu-l4t) resolve to the new
#   consolidated build (azahar-emu-arm64-legacy) transparently.
#
#   If per-distro meta files exist (meta/provides.<distro>), the aliases are
#   appended to every one of them (perf-libs case). Otherwise they go to the
#   plain meta/provides and meta/replaces.
set -euo pipefail

basename="${1:-}"
meta_dir="${2:-}"

if [[ -z "$basename" || -z "$meta_dir" ]]; then
  echo "Usage: $0 <basename> <meta_dir>" >&2
  exit 1
fi

[[ -z "${TARGET_DEVICES:-}" ]] && exit 0

mapfile -t provides_distro < <(shopt -s nullglob; printf '%s\n' "$meta_dir"/provides.*)
mapfile -t replaces_distro < <(shopt -s nullglob; printf '%s\n' "$meta_dir"/replaces.*)

IFS=',' read -ra aliases <<< "$TARGET_DEVICES"
for alias in "${aliases[@]}"; do
  [[ -z "$alias" ]] && continue
  entry="${basename}-${alias}"

  if (( ${#provides_distro[@]} > 0 )); then
    for f in "${provides_distro[@]}"; do echo "$entry" >> "$f"; done
  else
    echo "$entry" >> "$meta_dir/provides"
  fi

  if (( ${#replaces_distro[@]} > 0 )); then
    for f in "${replaces_distro[@]}"; do echo "$entry" >> "$f"; done
  else
    echo "$entry" >> "$meta_dir/replaces"
  fi
done
