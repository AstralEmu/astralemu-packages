#!/bin/bash
# finalize-meta.sh — Write the metadata fields that are identical across
# every package built by this pipeline.
#
# Usage: finalize-meta.sh <meta_dir> [<src_dir>]
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
# When the optional <src_dir> argument is given, scans that directory
# for the upstream LICENSE / COPYING / NOTICE / COPYRIGHT files and
# copies them into <pkg_root>/usr/share/doc/<pkg_name>/. <pkg_root> is
# derived as the sibling 'root' directory next to <meta_dir>. Required
# by GPL §1 (binaries must ship with the copyright notice) — automated
# here so each build.sh only needs to pass the SRC dir it cloned.
#
# Per-package fields (name, description, depends, section, priority,
# provides, replaces, conflicts, …) stay in each build.sh — those genuinely
# differ between packages.
set -euo pipefail

meta_dir="${1:-}"
src_dir="${2:-}"
[[ -n "$meta_dir" && -d "$meta_dir" ]] || {
  echo "Usage: $0 <meta_dir> [<src_dir>]" >&2
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

# license retention: copy upstream LICENSE / COPYING / NOTICE / COPYRIGHT
# files into <pkg_root>/usr/share/doc/<pkg_name>/. Caller must pass the
# upstream source directory as the second argument.
if [[ -n "$src_dir" && -d "$src_dir" ]]; then
  if [[ ! -f "$meta_dir/name" ]]; then
    echo "WARN: no meta/name found, skipping license retention" >&2
  else
    pkg_name=$(cat "$meta_dir/name")
    doc_dir="$(dirname "$meta_dir")/root/usr/share/doc/$pkg_name"
    mkdir -p "$doc_dir"
    found=0
    for f in LICENSE LICENSE.txt LICENSE.md LICENSE-MIT LICENSE-APACHE \
             COPYING COPYING.LIB COPYING.LESSER COPYRIGHT NOTICE \
             AUTHORS AUTHORS.md CREDITS; do
      if [[ -f "$src_dir/$f" ]]; then
        cp "$src_dir/$f" "$doc_dir/"
        found=$((found + 1))
      fi
    done
    if (( found > 0 )); then
      echo "  retained $found license/copyright file(s) -> usr/share/doc/$pkg_name/"
    else
      echo "  WARN: no LICENSE/COPYING/NOTICE found under $src_dir" >&2
    fi
  fi
fi
