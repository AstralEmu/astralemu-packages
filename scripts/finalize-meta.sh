#!/bin/bash
# finalize-meta.sh — Write the metadata fields that are identical across
# every package built by this pipeline.
#
# Usage: finalize-meta.sh <meta_dir>
#
# Sourced from each emulator/package build.sh after it has produced
# the package-specific fields (name, version, arch, description, depends,
# section, priority, ...). This is where the source-of-truth values for
# fields that don't change per emulator land:
#   - source_distro  : value of $SOURCE_DISTRO env var (set by build-chain.yml
#                       from build_targets[].source_distro in devices.yml)
#   - source_format  : the native package format of the source distro
#                       (deb for ubuntu-lts/debian-stable, rpm for
#                        fedora-latest, pacman for arch). Derived dynamically from
#                        distros.yml so adding a new source distro doesn't
#                        require touching every build.sh.
#   - maintainer     : single source of truth (the maintainer string was
#                       previously copy-pasted in 10+ scripts).
#
# Per-package fields (name, description, depends, section, priority,
# provides, replaces, conflicts, …) stay in each build.sh — those genuinely
# differ between packages.
set -euo pipefail

meta_dir="${1:-}"
[[ -n "$meta_dir" && -d "$meta_dir" ]] || {
  echo "Usage: $0 <meta_dir>" >&2
  exit 1
}

# source_distro: required, must come from the pipeline.
if [[ -z "${SOURCE_DISTRO:-}" ]]; then
  echo "ERROR: SOURCE_DISTRO env var not set — caller must pass it" >&2
  exit 1
fi
echo "$SOURCE_DISTRO" > "$meta_dir/source_distro"

# source_format: derived from distros.yml by matching SOURCE_DISTRO against
# the apt/dnf/pacman entries. Falls back to deb if the lookup fails (most
# common case, keeps existing behaviour).
distros_yml="${ASTRALEMU_DISTROS_YML:-/workspace/distros.yml}"
src_format="deb"
if command -v yq >/dev/null && [[ -f "$distros_yml" ]]; then
  for fmt_key in apt:deb dnf:rpm pacman:pacman; do
    yml_key="${fmt_key%:*}"
    fmt_val="${fmt_key#*:}"
    if yq -e ".distros.${yml_key}[] | select(.id == \"$SOURCE_DISTRO\")" "$distros_yml" >/dev/null 2>&1; then
      src_format="$fmt_val"
      break
    fi
  done
fi
echo "$src_format" > "$meta_dir/source_format"

# maintainer: project-wide constant, override via env if needed.
echo "${ASTRALEMU_MAINTAINER:-AstralEmu <noreply@astralemu.github.io>}" \
  > "$meta_dir/maintainer"
