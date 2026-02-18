#!/bin/bash
# cross-pkg-helpers.sh — Shared functions for cross-distro package building
# Sourced by pkg-build-rpm.sh, pkg-build-pacman.sh, and pkg-build-deb.sh
#
# Handles ALL conversion paths: deb↔rpm↔pacman in every direction.

# ========================================================================
# relocate_lib_paths: Move library files between distro path conventions
#
# Handles:
#   1. Debian multiarch triplets: /lib/<triplet>/, /usr/lib/<triplet>/ → target
#   2. RPM lib64: /usr/lib64/ → target (when target != /usr/lib64)
#   3. /lib/ → /usr/lib/ merge (for merged-usr distros)
#
# Creates compat symlinks from old paths for RPATH/dlopen compatibility.
#
# Usage: relocate_lib_paths <root-dir> <target-libdir>
# ========================================================================
relocate_lib_paths() {
  local root="$1" target_libdir="$2"
  [[ -d "$root" ]] || return 0

  local relocated=false

  # --- 1. Debian multiarch triplets ---
  local triplet
  for triplet in aarch64-linux-gnu arm-linux-gnueabihf x86_64-linux-gnu i386-linux-gnu; do
    for prefix in "$root/lib" "$root/usr/lib"; do
      local src_dir="$prefix/$triplet"
      [[ -d "$src_dir" ]] || continue
      relocated=true

      local dest_dir="$root$target_libdir"
      mkdir -p "$dest_dir"
      cp -a "$src_dir"/* "$dest_dir/" 2>/dev/null || true
      rm -rf "$src_dir"

      # Compat symlink: old multiarch path → new target
      local rel_target
      rel_target=$(python3 -c "import os; print(os.path.relpath('$dest_dir', '$(dirname "$src_dir")'))" 2>/dev/null) || \
        rel_target="$target_libdir"
      ln -sfn "$rel_target" "$src_dir"
    done
  done

  # --- 2. RPM lib64 → target (when different) ---
  if [[ -d "$root/usr/lib64" ]] && [[ "$target_libdir" != "/usr/lib64" ]]; then
    local dest_dir="$root$target_libdir"
    mkdir -p "$dest_dir"
    cp -a "$root/usr/lib64"/* "$dest_dir/" 2>/dev/null || true
    rm -rf "$root/usr/lib64"
    ln -sfn "$target_libdir" "$root/usr/lib64"
    relocated=true
  fi

  # --- 3. /lib/ → /usr/lib/ merge ---
  if [[ -d "$root/lib" ]] && [[ "$target_libdir" == /usr/lib* ]]; then
    local dest_dir="$root$target_libdir"
    mkdir -p "$dest_dir"
    for item in "$root/lib"/*; do
      [[ -e "$item" ]] || continue
      local base
      base=$(basename "$item")
      [[ -L "$item" ]] && continue
      [[ "$base" == "firmware" || "$base" == "modules" || "$base" == "udev" ]] && continue
      if [[ -f "$item" || -d "$item" ]]; then
        cp -a "$item" "$dest_dir/" 2>/dev/null || true
        rm -rf "$item"
      fi
    done
    relocated=true
  fi

  if [[ "$relocated" == "true" ]]; then
    echo "  Relocated library paths → $target_libdir"
  fi
}

# ========================================================================
# Translate adduser/addgroup → useradd/groupadd
# ========================================================================
translate_adduser_cmd() {
  local line="$1" nologin="${2:-/sbin/nologin}"
  local indent="${line%%[! ]*}"

  # addgroup --system <group>
  if [[ "$line" =~ addgroup[[:space:]]+--system[[:space:]]+([a-zA-Z0-9_-]+) ]]; then
    echo "${indent}getent group ${BASH_REMATCH[1]} >/dev/null || groupadd -r ${BASH_REMATCH[1]}"
    return
  fi

  # adduser <user> <group> (add user to group)
  if [[ "$line" =~ adduser[[:space:]]+([a-zA-Z0-9_-]+)[[:space:]]+([a-zA-Z0-9_-]+)[[:space:]]*$ ]] && \
     ! [[ "$line" =~ --system ]]; then
    echo "${indent}usermod -aG ${BASH_REMATCH[2]} ${BASH_REMATCH[1]} 2>/dev/null || :"
    return
  fi

  # adduser --system [flags] <username>
  if [[ "$line" =~ adduser[[:space:]]+--system ]]; then
    local user="" home="" shell="$nologin" group_flag="" no_create="-M"
    # shellcheck disable=SC2206
    local args=($line)
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
      case "${args[$i]}" in
        adduser|--system|--disabled-password|--disabled-login|--quiet) i=$((i+1)) ;;
        --home)           home="${args[$((i+1))]}"; i=$((i+2)) ;;
        --shell)          shell="${args[$((i+1))]}"; i=$((i+2)) ;;
        --no-create-home) no_create="-M"; i=$((i+1)) ;;
        --group)          group_flag="same"; i=$((i+1)) ;;
        --ingroup)        group_flag="${args[$((i+1))]}"; i=$((i+2)) ;;
        --gecos)          i=$((i+2)) ;;
        *)                user="${args[$i]}"; i=$((i+1)) ;;
      esac
    done

    if [[ -n "$user" ]]; then
      local cmd="useradd -r $no_create -s $shell"
      [[ -n "$home" ]] && cmd="$cmd -d $home"
      if [[ "$group_flag" == "same" ]]; then
        echo "${indent}getent group $user >/dev/null || groupadd -r $user"
        cmd="$cmd -g $user"
      elif [[ -n "$group_flag" ]]; then
        cmd="$cmd -g $group_flag"
      fi
      echo "${indent}getent passwd $user >/dev/null || $cmd $user"
    fi
    return
  fi

  echo "$line"
}

# ========================================================================
# Unified script translation: any source format → any target format
#
# Usage: translate_script <script-file> <source-fmt> <target-fmt> [rpm-$1-value]
#
#   rpm-$1-value: Only needed when source is RPM and target is NOT RPM.
#     Numeric value: replaces $1 with fixed number (for pacman dual-call)
#     "runtime": replaces $1 with $_RPM_ARG (caller prepends preamble)
#     Values: 0=uninstall, 1=install, 2=upgrade, "runtime"=dynamic
#
# Handles all 9 combinations:
#   deb→rpm, deb→pacman, deb→deb (passthrough)
#   rpm→deb, rpm→pacman, rpm→rpm (passthrough)
#   pacman→deb, pacman→rpm, pacman→pacman (passthrough)
# ========================================================================
translate_script() {
  local script_file="$1" source_fmt="$2" target_fmt="$3" rpm_arg="${4:-}"
  [[ -f "$script_file" ]] || return

  # --- Same format: just strip boilerplate ---
  if [[ "$source_fmt" == "$target_fmt" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^#! ]] && continue
      [[ "$line" =~ ^[[:space:]]*set[[:space:]]+-e ]] && continue
      echo "$line"
    done < "$script_file"
    return
  fi

  # Target nologin path
  local nologin
  case "$target_fmt" in
    deb)    nologin="/usr/sbin/nologin" ;;
    rpm)    nologin="/sbin/nologin" ;;
    pacman) nologin="/usr/bin/nologin" ;;
  esac

  # Deb case block state (with nested case depth tracking)
  local in_deb_case=false
  local in_active_block=false
  local case_depth=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # --- Common: skip shebang, set -e ---
    [[ "$line" =~ ^#! ]] && continue
    [[ "$line" =~ ^[[:space:]]*set[[:space:]]+-e ]] && continue

    # =============================================================
    # SOURCE-SPECIFIC STRIPPING
    # =============================================================

    # --- Debian source: case dispatcher + debconf + dpkg-* ---
    if [[ "$source_fmt" == "deb" ]]; then

      # Detect outer case "$1" / case $1 / case "${1}" wrapper
      if [[ "$in_deb_case" != "true" ]] && \
         [[ "$line" =~ case[[:space:]]+(\"?\$1\"?|\"\$\{1\}\"|\'?\$1\'?|\$1)[[:space:]] ]]; then
        in_deb_case=true
        case_depth=1
        continue
      fi

      if [[ "$in_deb_case" == "true" ]]; then
        # Track nested case ... in (at any depth, even in inactive blocks)
        if [[ "$line" =~ ^[[:space:]]*case[[:space:]] ]] && [[ "$line" =~ [[:space:]]in[[:space:]]*$ ]]; then
          case_depth=$((case_depth + 1))
          [[ "$in_active_block" == "true" ]] && echo "$line"
          continue
        fi

        # esac — decrement depth
        if [[ "$line" =~ ^[[:space:]]*esac ]]; then
          case_depth=$((case_depth - 1))
          if [[ $case_depth -le 0 ]]; then
            # Outer case block ends
            in_deb_case=false
            in_active_block=false
            case_depth=0
            continue
          fi
          # Inner esac — pass through if in active block
          [[ "$in_active_block" == "true" ]] && echo "$line"
          continue
        fi

        # Only interpret case structure at outer level (depth 1)
        if [[ $case_depth -eq 1 ]]; then
          # Active blocks: configure, install, upgrade, remove, purge
          if [[ "$line" =~ ^[[:space:]]*(configure|install|upgrade|remove|purge)\) ]]; then
            in_active_block=true
            continue
          fi
          # Skip blocks: abort-*, failed-*, deconfigure, disappear, wildcard
          if [[ "$line" =~ ^[[:space:]]*(abort|failed|deconfigure|disappear) ]] || \
             [[ "$line" =~ ^[[:space:]]*\*\) ]]; then
            in_active_block=false
            continue
          fi
          # ;; between outer cases
          if [[ "$line" =~ ^[[:space:]]*\;\; ]]; then
            in_active_block=false
            continue
          fi
        fi

        # Inside active block → pass through for further processing
        # Inside skipped block → drop
        [[ "$in_active_block" != "true" ]] && continue
      fi

      # dpkg --compare-versions → if false
      if [[ "$line" =~ dpkg[[:space:]]+--compare-versions ]]; then
        echo "${line%%if*}if false; then"
        continue
      fi

      # Strip Debian-only commands
      [[ "$line" =~ dpkg-maintscript-helper ]] && continue
      [[ "$line" =~ dpkg-trigger ]] && continue
      [[ "$line" =~ deb-systemd-helper ]] && continue
      [[ "$line" =~ deb-systemd-invoke ]] && continue
      [[ "$line" =~ update-rc\.d ]] && continue
      [[ "$line" =~ invoke-rc\.d ]] && continue
      [[ "$line" =~ /usr/share/debconf/confmodule ]] && continue
      [[ "$line" =~ db_get ]] && continue
      [[ "$line" =~ db_set ]] && continue
      [[ "$line" =~ db_input ]] && continue
      [[ "$line" =~ db_go ]] && continue
      [[ "$line" =~ db_stop ]] && continue
      [[ "$line" =~ db_purge ]] && continue
    fi

    # --- RPM source: replace $1 with simulated value or runtime variable ---
    # When RPM scripts run on deb/pacman, $1 is not numeric.
    # "runtime": replace $1 with $_RPM_ARG (caller prepends preamble to compute it)
    # numeric: replace $1 with fixed value (for pacman dual-call splitting)
    if [[ "$source_fmt" == "rpm" ]] && [[ -n "$rpm_arg" ]]; then
      if [[ "$rpm_arg" == "runtime" ]]; then
        line="${line//\$\{1\}/\${_RPM_ARG}}"
        line="${line//\$1/\${_RPM_ARG}}"
      else
        line="${line//\$\{1\}/$rpm_arg}"
        line="${line//\$1/$rpm_arg}"
      fi
    fi

    # =============================================================
    # COMMAND TRANSLATIONS (bidirectional, any source → any target)
    # =============================================================

    # --- ldconfig: keep for deb/rpm, strip for pacman (alpm hooks) ---
    if [[ "$line" =~ ldconfig ]]; then
      [[ "$target_fmt" == "pacman" ]] && continue
      echo "$line"
      continue
    fi

    # --- initramfs: update-initramfs (deb) ↔ dracut (rpm) ↔ mkinitcpio (pacman) ---
    if [[ "$line" =~ update-initramfs ]] || [[ "$line" =~ dracut ]] || [[ "$line" =~ mkinitcpio ]]; then
      local indent="${line%%[! ]*}"
      case "$target_fmt" in
        deb)    echo "${indent}update-initramfs -u 2>/dev/null || :" ;;
        rpm)    echo "${indent}dracut --force 2>/dev/null || :" ;;
        pacman) echo "${indent}mkinitcpio -P 2>/dev/null || :" ;;
      esac
      continue
    fi

    # --- grub: update-grub (deb) ↔ grub2-mkconfig (rpm) ↔ grub-mkconfig (pacman) ---
    if [[ "$line" =~ update-grub ]] || [[ "$line" =~ grub2-mkconfig ]] || [[ "$line" =~ grub-mkconfig ]]; then
      local indent="${line%%[! ]*}"
      case "$target_fmt" in
        deb)    echo "${indent}update-grub 2>/dev/null || :" ;;
        rpm)    echo "${indent}grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || :" ;;
        pacman) echo "${indent}grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || :" ;;
      esac
      continue
    fi

    # --- alternatives: update-alternatives (deb) ↔ alternatives (rpm) ↔ [none] (pacman) ---
    if [[ "$line" == *"update-alternatives"* ]]; then
      # Source is deb (has update-alternatives)
      case "$target_fmt" in
        pacman) continue ;;
        rpm)    line="${line//update-alternatives/alternatives}" ;;
      esac
    elif [[ "$line" =~ ^[[:space:]]*(\/usr\/sbin\/)?alternatives[[:space:]] ]]; then
      # Source is rpm (has alternatives or /usr/sbin/alternatives)
      case "$target_fmt" in
        pacman) continue ;;
        deb)
          line="${line//\/usr\/sbin\/alternatives/update-alternatives}"
          line="${line//alternatives/update-alternatives}"
          line="${line//update-update-alternatives/update-alternatives}"
          ;;
      esac
    fi

    # --- adduser/addgroup → useradd/groupadd (Debian source only) ---
    # RPM/Pacman sources already use useradd/groupadd natively
    if [[ "$source_fmt" == "deb" ]]; then
      if [[ "$line" =~ adduser ]] || [[ "$line" =~ addgroup[[:space:]]+--system ]]; then
        translate_adduser_cmd "$line" "$nologin"
        continue
      fi
    fi

    # --- nologin path normalization ---
    if [[ "$line" == *"nologin"* ]]; then
      line="${line//\/usr\/sbin\/nologin/$nologin}"
      line="${line//\/sbin\/nologin/$nologin}"
      line="${line//\/usr\/bin\/nologin/$nologin}"
    fi

    echo "$line"
  done < "$script_file"
}

# ========================================================================
# Extract conffiles list from intermediate format
# Returns one absolute path per line
# ========================================================================
get_conffiles() {
  local intdir="$1"
  if [[ -s "$intdir/meta/conffiles" ]]; then
    grep -v '^$' "$intdir/meta/conffiles" 2>/dev/null || true
  fi
}
