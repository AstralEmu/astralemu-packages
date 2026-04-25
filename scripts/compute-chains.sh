#!/bin/bash
# compute-chains.sh — Compute build chains from emulators.yml + packages.yml + devices.yml
#
# Reads emulator and package definitions, merges them, applies power scoring,
# bin-packs into 4 parallel chains by build_time, and outputs
# chain matrices split into independent/dependent levels.
#
# Inputs (env vars):
#   VERSIONS_JSON  — JSON object: { "emulator-id": "version-string", ... }
#   MARKERS_LIST   — Newline-separated list of existing success-* cache keys
#   FORCE          — "true" to force rebuild all
#   GITHUB_OUTPUT  — Path to GitHub Actions output file
#
# Outputs (to $GITHUB_OUTPUT):
#   chain_1_ind .. chain_4_ind  — Independent emulators per chain
#   chain_1_dep .. chain_4_dep  — Dependent emulators per chain
#   aggregators                 — Aggregator emulators (need all chains)
#   any_build                   — "true" if at least one emulator needs building
#   versions_json               — Aggregated versions for save-trackers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Convert YAML to JSON once, then use jq for everything
# Merge emulators.yml and packages.yml into one array, tagging each with _base_dir
EMUS_ONLY=$(yq -o=json '.emulators' "$ROOT_DIR/emulators.yml")
PKGS_ONLY=$(yq -o=json '.packages // []' "$ROOT_DIR/packages.yml")
EMUS_JSON=$(echo "$EMUS_ONLY" "$PKGS_ONLY" | jq -s '
  ([.[0][] | . + {_base_dir: "emulators"}]) +
  ([.[1][] | . + {_base_dir: "packages"}])')
DEVS_JSON=$(yq -o=json '.devices' "$ROOT_DIR/devices.yml")
TARGETS_JSON=$(yq -o=json '.build_targets' "$ROOT_DIR/devices.yml")

# For each build_target, collect its devices (aliases) and the max power score
# across all devices mapping to it. Emulators are filtered on the max power —
# if any device on the target can run the emulator, we build for the target.
TARGETS_JSON=$(echo "$TARGETS_JSON" "$DEVS_JSON" | jq -s '
  .[0] as $targets |
  .[1] as $devs |
  $targets | map(
    . as $t |
    ($devs | map(select(.build_target == $t.id))) as $members |
    . + {
      devices: ($members | map(.id)),
      max_power: ($members | map(.power // 1) | max // 1)
    }
  )')

emu_count=$(echo "$EMUS_JSON" | jq 'length')
target_count=$(echo "$TARGETS_JSON" | jq 'length')

# --- Step 1: Compute hashes (build script + emulator config entry) ---
HASHES="{}"
for (( i=0; i<emu_count; i++ )); do
  emu_id=$(echo "$EMUS_JSON" | jq -r ".[$i].id")
  base_dir=$(echo "$EMUS_JSON" | jq -r ".[$i]._base_dir")
  script_path="$ROOT_DIR/$base_dir/$emu_id/build.sh"
  config_entry=$(echo "$EMUS_JSON" | jq -c ".[$i]")
  if [[ -f "$script_path" ]]; then
    hash=$(cat "$script_path" <(echo -n "$config_entry") | sha256sum | cut -d' ' -f1)
  else
    hash=$(echo -n "$config_entry" | sha256sum | cut -d' ' -f1)
  fi
  HASHES=$(echo "$HASHES" | jq --arg id "$emu_id" --arg h "$hash" '. + {($id): $h}')
  echo "hash_${emu_id//-/_}=$hash" >> "$GITHUB_OUTPUT"
done

# --- Step 2: Decide build/skip per emulator ---
BUILDS="{}"
for (( i=0; i<emu_count; i++ )); do
  emu_id=$(echo "$EMUS_JSON" | jq -r ".[$i].id")
  version_source=$(echo "$EMUS_JSON" | jq -r ".[$i].version_source")
  tracker_file=$(echo "$EMUS_JSON" | jq -r ".[$i].tracker_file // empty")
  hash=$(echo "$HASHES" | jq -r ".\"$emu_id\"")

  # Get version from VERSIONS_JSON
  version=""
  short=""
  if [[ -n "${VERSIONS_JSON:-}" ]] && [[ "$version_source" != "hash-only" ]]; then
    version=$(echo "$VERSIONS_JSON" | jq -r ".\"$emu_id\" // empty")
    if [[ "$version_source" == "github-commit" ]]; then
      short="${version:0:7}"
    fi
  fi

  # Output version for save-trackers
  if [[ -n "$version" ]]; then
    echo "version_${emu_id//-/_}=$version" >> "$GITHUB_OUTPUT"
    if [[ -n "$short" ]]; then
      echo "short_${emu_id//-/_}=$short" >> "$GITHUB_OUTPUT"
    fi
  fi

  # Check if version changed (applies to all targets equally)
  ver_changed="false"
  if [[ -n "$tracker_file" ]] && [[ -n "$version" ]]; then
    current=$(cat "$ROOT_DIR/.trackers/$tracker_file" 2>/dev/null || echo "")
    if [[ "$version" != "$current" ]]; then
      ver_changed="true"
    fi
  fi

  # Emu-level flag: always true at this stage. The real per-target skip
  # decision happens in step 4, which checks the exact marker
  # success-<emu>-<target>-<hash> for each (emu, target) pair. Keeping
  # BUILDS[emu]=true here lets step 2b propagate deps correctly; any
  # emu with no surviving targets after step 4 simply contributes zero
  # entries to the matrix.
  BUILDS=$(echo "$BUILDS" | jq --arg id "$emu_id" '. + {($id): true}')
  echo "  $emu_id: CONSIDER (force=${FORCE:-false} ver_changed=$ver_changed)"
done

# --- Step 2b: If an aggregator/dependent needs building, force its deps too ---
# Aggregators download artifacts from the same run, so deps must produce them.
changed="true"
while [[ "$changed" == "true" ]]; do
  changed="false"
  for (( i=0; i<emu_count; i++ )); do
    emu_id=$(echo "$EMUS_JSON" | jq -r ".[$i].id")
    should_build=$(echo "$BUILDS" | jq -r ".\"$emu_id\"")
    [[ "$should_build" != "true" ]] && continue

    deps=$(echo "$EMUS_JSON" | jq -r ".[$i].depends_on // [] | .[]")
    for dep_id in $deps; do
      dep_build=$(echo "$BUILDS" | jq -r ".\"$dep_id\"")
      if [[ "$dep_build" != "true" ]]; then
        BUILDS=$(echo "$BUILDS" | jq --arg id "$dep_id" '. + {($id): true}')
        echo "  $dep_id: BUILD (required by $emu_id)"
        changed="true"
      fi
    done
  done
done

# --- Step 3: Assign emulators to 4 chains using build_time bin-packing ---
# 4 chains × max-parallel 3 = 12 concurrent jobs
# Each chain has 2 levels: ind (independent) and dep (dependent)
# Aggregators run after all chains complete
NUM_CHAINS=4

CHAINS="{}"  # emulator_id → chain number (1-4, or 0 for aggregators)
LEVELS="{}"  # emulator_id → "ind" | "dep" | "agg"

# Initialize chain loads
declare -a CHAIN_LOADS
for (( c=0; c<NUM_CHAINS; c++ )); do
  CHAIN_LOADS[$c]=0
done

# Sort emulators by build_time descending for greedy bin-packing
SORTED=$(echo "$EMUS_JSON" | jq -r '
  [range(length) as $i | {idx: $i, id: .[$i].id, bt: (.[$i].build_time // 30)}]
  | sort_by(-.bt)
  | .[] | "\(.idx) \(.id) \(.bt)"')

# Pass 1: Bin-pack independent emulators (no depends_on, not aggregator)
while IFS=' ' read -r idx emu_id build_time; do
  [[ -z "$emu_id" ]] && continue
  should_build=$(echo "$BUILDS" | jq -r ".\"$emu_id\"")
  [[ "$should_build" != "true" ]] && continue
  dep_count=$(echo "$EMUS_JSON" | jq ".[$idx].depends_on // [] | length")
  [[ "$dep_count" -ne 0 ]] && continue
  is_agg=$(echo "$EMUS_JSON" | jq -r ".[$idx].is_aggregator // false")
  [[ "$is_agg" == "true" ]] && continue

  # Find chain with lowest load
  best=0
  for (( c=1; c<NUM_CHAINS; c++ )); do
    (( CHAIN_LOADS[c] < CHAIN_LOADS[best] )) && best=$c
  done

  CHAINS=$(echo "$CHAINS" | jq --arg id "$emu_id" --argjson c "$(( best + 1 ))" '. + {($id): $c}')
  LEVELS=$(echo "$LEVELS" | jq --arg id "$emu_id" '. + {($id): "ind"}')
  CHAIN_LOADS[$best]=$(( CHAIN_LOADS[best] + build_time ))
done <<< "$SORTED"

# Pass 2: Assign dependent emulators (non-aggregator) to same chain as first dependency
while IFS=' ' read -r idx emu_id build_time; do
  [[ -z "$emu_id" ]] && continue
  should_build=$(echo "$BUILDS" | jq -r ".\"$emu_id\"")
  [[ "$should_build" != "true" ]] && continue
  deps=$(echo "$EMUS_JSON" | jq -c ".[$idx].depends_on // []")
  dep_count=$(echo "$deps" | jq 'length')
  [[ "$dep_count" -eq 0 ]] && continue
  is_agg=$(echo "$EMUS_JSON" | jq -r ".[$idx].is_aggregator // false")
  [[ "$is_agg" == "true" ]] && continue

  # Assign to same chain as first dependency
  first_dep=$(echo "$deps" | jq -r '.[0]')
  chain=$(echo "$CHAINS" | jq -r ".\"$first_dep\" // 1")

  CHAINS=$(echo "$CHAINS" | jq --arg id "$emu_id" --argjson c "$chain" '. + {($id): $c}')
  LEVELS=$(echo "$LEVELS" | jq --arg id "$emu_id" '. + {($id): "dep"}')
  CHAIN_LOADS[$((chain - 1))]=$(( CHAIN_LOADS[chain - 1] + build_time ))
done <<< "$SORTED"

# Pass 3: Aggregators (depend on entries across all chains)
while IFS=' ' read -r idx emu_id build_time; do
  [[ -z "$emu_id" ]] && continue
  should_build=$(echo "$BUILDS" | jq -r ".\"$emu_id\"")
  [[ "$should_build" != "true" ]] && continue
  is_agg=$(echo "$EMUS_JSON" | jq -r ".[$idx].is_aggregator // false")
  [[ "$is_agg" != "true" ]] && continue

  CHAINS=$(echo "$CHAINS" | jq --arg id "$emu_id" '. + {($id): 0}')
  LEVELS=$(echo "$LEVELS" | jq --arg id "$emu_id" '. + {($id): "agg"}')
done <<< "$SORTED"

echo "Chain load distribution:"
for (( c=0; c<NUM_CHAINS; c++ )); do
  echo "  Chain $(( c + 1 )): ${CHAIN_LOADS[$c]} minutes"
done

# --- Step 3b: Aggregator artifact reuse / forced dep rebuild --------------
# When an aggregator (e.g. libretro-package) needs to rebuild but its deps
# (libretro-heavy-*, libretro-light) are still marker-cached, the current
# run won't produce the libretro-cores-* artifacts the aggregator consumes.
# Two ways out:
#   1. Pull the cores from the latest successful build-emulators run (fast,
#      free — fits inside GitHub's 1-day artifact retention).
#   2. Force the deps to rebuild this run (slow, but always correct).
# We prefer (1) and fall back to (2) when artifacts are missing/expired.
#
# AGG_FALLBACK_RUN[$emu_id:$tgt_id] = run_id  → pull from that run
# FORCE_DEP_REBUILD[$dep_id:$tgt_id] = 1      → ignore marker, rebuild
declare -A AGG_FALLBACK_RUN
declare -A FORCE_DEP_REBUILD

# Probe the latest successful build-emulators run (other than ours).
LATEST_RUN_ID=""
LATEST_RUN_ARTIFACTS=""
if command -v gh >/dev/null && [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
  LATEST_RUN_ID=$(gh api "/repos/${GITHUB_REPOSITORY}/actions/workflows/build-emulators.yml/runs?status=success&per_page=10" \
    --jq ".workflow_runs[] | select(.id != ${GITHUB_RUN_ID:-0}) | .id" 2>/dev/null | head -1)
  if [[ -n "$LATEST_RUN_ID" ]]; then
    LATEST_RUN_ARTIFACTS=$(gh api --paginate \
      "/repos/${GITHUB_REPOSITORY}/actions/runs/${LATEST_RUN_ID}/artifacts" \
      --jq '.artifacts[] | select(.expired == false) | .name' 2>/dev/null)
    echo "Probing fallback artifacts from run ${LATEST_RUN_ID}: $(echo "$LATEST_RUN_ARTIFACTS" | wc -l) entries"
  fi
fi

# For each (aggregator × target) that needs a build, decide between
# fallback-run download and forcing dep rebuild.
for (( i=0; i<emu_count; i++ )); do
  is_agg=$(echo "$EMUS_JSON" | jq -r ".[$i].is_aggregator // false")
  [[ "$is_agg" != "true" ]] && continue

  emu_id=$(echo "$EMUS_JSON" | jq -r ".[$i].id")
  hash=$(echo "$HASHES" | jq -r ".\"$emu_id\"")
  deps=$(echo "$EMUS_JSON" | jq -r ".[$i].depends_on // [] | .[]")
  # Aggregators are not per_device, so iterate build_targets.
  for tgt_id in $(echo "$TARGETS_JSON" | jq -r '.[].id'); do
    marker="success-${emu_id}-${tgt_id}-${hash}"
    if [[ "${FORCE:-false}" != "true" ]] && [[ "${ver_changed:-false}" != "true" ]] \
       && echo "${MARKERS_LIST:-}" | grep -qF "$marker"; then
      continue  # Aggregator marker present, nothing to do for this target
    fi
    # Check if all dep artifacts are available in the fallback run
    all_dep_arts=true
    for dep_id in $deps; do
      art_name="libretro-cores-${dep_id}-${tgt_id}"
      if ! echo "$LATEST_RUN_ARTIFACTS" | grep -qF -x "$art_name"; then
        all_dep_arts=false
        break
      fi
    done
    if [[ "$all_dep_arts" == "true" ]]; then
      AGG_FALLBACK_RUN["${emu_id}:${tgt_id}"]="$LATEST_RUN_ID"
      echo "  $emu_id/$tgt_id: will reuse cores artifacts from run $LATEST_RUN_ID"
    else
      for dep_id in $deps; do
        FORCE_DEP_REBUILD["${dep_id}:${tgt_id}"]=1
      done
      echo "  $emu_id/$tgt_id: deps must rebuild (no fallback artifacts)"
    fi
  done
done

# --- Step 4: Build matrix entries, accumulate into ALL_ENTRIES with chain/level fields ---
ALL_ENTRIES="[]"

# Start the build-matrix report in $GITHUB_STEP_SUMMARY. We tally counts
# as rows are emitted and print a summary footer at the end.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/report.sh"
report_section "Build matrix"
report_table "Emulator" "Target" "Status" "Reason" "Version"
report_build_count=0
report_skip_marker=0
report_skip_power=0
report_skip_arch=0

for (( i=0; i<emu_count; i++ )); do
  emu_id=$(echo "$EMUS_JSON" | jq -r ".[$i].id")

  should_build=$(echo "$BUILDS" | jq -r ".\"$emu_id\"")
  if [[ "$should_build" != "true" ]]; then
    continue
  fi

  chain=$(echo "$CHAINS" | jq -r ".\"$emu_id\" // 1")
  level=$(echo "$LEVELS" | jq -r ".\"$emu_id\" // \"ind\"")
  emu_data=$(echo "$EMUS_JSON" | jq -c ".[$i]")
  true_arm=$(echo "$emu_data" | jq -r '.true_arm // false')
  true_amd=$(echo "$emu_data" | jq -r '.true_amd // false')
  power_arm=$(echo "$emu_data" | jq -r '.power_arm // 1')
  power_amd=$(echo "$emu_data" | jq -r '.power_amd // 1')
  base_dir=$(echo "$emu_data" | jq -r '._base_dir // "emulators"')
  artifact_type=$(echo "$emu_data" | jq -r '.artifact_type // "pkg"')
  is_aggregator=$(echo "$emu_data" | jq -r '.is_aggregator // false')
  per_device=$(echo "$emu_data" | jq -r '.per_device // false')
  extra_cache_key=$(echo "$emu_data" | jq -r '.extra_caches[0].key // empty')
  extra_cache_path=$(echo "$emu_data" | jq -r '.extra_caches[0].path // empty')
  extra_cache_mount=$(echo "$emu_data" | jq -r '.extra_caches[0].mount // empty')
  extra_cache_save=$(echo "$emu_data" | jq -r '.extra_caches[0].save // false')
  hash=$(echo "$HASHES" | jq -r ".\"$emu_id\"")

  # Get version info
  version=""
  short=""
  if [[ -n "${VERSIONS_JSON:-}" ]]; then
    version=$(echo "$VERSIONS_JSON" | jq -r ".\"$emu_id\" // empty")
    version_source=$(echo "$emu_data" | jq -r '.version_source')
    if [[ "$version_source" == "github-commit" ]]; then
      short="${version:0:7}"
    fi
  fi
  version_short="${short:-$version}"

  # per_device=true emulators (e.g. setperf) iterate over devices directly;
  # each device gets its own build with TARGET_ID=<device_id> and no alias.
  # All other emulators iterate over build_targets (compilation deduplication).
  if [[ "$per_device" == "true" ]]; then
    ITER_JSON=$(echo "$DEVS_JSON" | jq -c '[.[] | {
      id: .id,
      arch: (.build_target as $bt | '"$TARGETS_JSON"' | map(select(.id == $bt))[0].arch),
      runner: (.build_target as $bt | '"$TARGETS_JSON"' | map(select(.id == $bt))[0].runner),
      platform: (.build_target as $bt | '"$TARGETS_JSON"' | map(select(.id == $bt))[0].platform),
      cflags: (.build_target as $bt | '"$TARGETS_JSON"' | map(select(.id == $bt))[0].cflags),
      cxxflags: (.build_target as $bt | '"$TARGETS_JSON"' | map(select(.id == $bt))[0].cxxflags),
      source_distro: (.build_target as $bt | '"$TARGETS_JSON"' | map(select(.id == $bt))[0].source_distro),
      max_power: (.power // 1),
      devices: [.id]
    }]')
    # Drop devices that have no per-device payload directory under
    # packages/<emu>/<device>/ — running them would just exit 0 from the
    # build script ("No setperf script for device X, skipping") and waste
    # a Docker container per device per run since no marker is uploaded.
    base_dir_path="$ROOT_DIR/$base_dir/$emu_id"
    if [[ -d "$base_dir_path" ]]; then
      available_devs=()
      for d in "$base_dir_path"/*/; do
        [[ -d "$d" ]] && available_devs+=("$(basename "$d")")
      done
      if (( ${#available_devs[@]} > 0 )); then
        avail_json=$(printf '%s\n' "${available_devs[@]}" | jq -R . | jq -s .)
        BEFORE=$(echo "$ITER_JSON" | jq 'length')
        ITER_JSON=$(echo "$ITER_JSON" | jq --argjson avail "$avail_json" -c \
          '[.[] | select(.id as $id | $avail | index($id))]')
        AFTER=$(echo "$ITER_JSON" | jq 'length')
        if (( AFTER < BEFORE )); then
          echo "  $emu_id: filtered $((BEFORE - AFTER)) device(s) without payload (kept $AFTER: ${available_devs[*]})"
        fi
      fi
    fi
  else
    ITER_JSON="$TARGETS_JSON"
  fi
  iter_count=$(echo "$ITER_JSON" | jq 'length')

  for (( j=0; j<iter_count; j++ )); do
    tgt_data=$(echo "$ITER_JSON" | jq -c ".[$j]")
    tgt_arch=$(echo "$tgt_data" | jq -r '.arch')
    tgt_power=$(echo "$tgt_data" | jq -r '.max_power // 1')
    tgt_id=$(echo "$tgt_data" | jq -r '.id')
    tgt_devices=$(echo "$tgt_data" | jq -r '.devices | join(" ")')

    # Power score + arch filter — we build for the target if any device on it
    # meets the emulator's power requirement.
    if [[ "$tgt_arch" == "arm64" ]]; then
      if [[ "$true_arm" != "true" ]]; then
        report_row "SKIP" "$emu_id" "$tgt_id" "arch: true_arm=false" "-"
        report_skip_arch=$((report_skip_arch+1))
        continue
      fi
      if (( tgt_power < power_arm )); then
        echo "  Skipping $emu_id on $tgt_id (max power $tgt_power < $power_arm for arm)"
        report_row "SKIP" "$emu_id" "$tgt_id" "power $tgt_power < required $power_arm" "-"
        report_skip_power=$((report_skip_power+1))
        continue
      fi
    elif [[ "$tgt_arch" == "amd64" ]]; then
      if [[ "$true_amd" != "true" ]]; then
        report_row "SKIP" "$emu_id" "$tgt_id" "arch: true_amd=false" "-"
        report_skip_arch=$((report_skip_arch+1))
        continue
      fi
      if (( tgt_power < power_amd )); then
        echo "  Skipping $emu_id on $tgt_id (max power $tgt_power < $power_amd for amd)"
        report_row "SKIP" "$emu_id" "$tgt_id" "power $tgt_power < required $power_amd" "-"
        report_skip_power=$((report_skip_power+1))
        continue
      fi
    fi

    # Skip this target if it already has a success marker for the exact
    # (emu, target, hash) triple — unless we were forced / version changed
    # OR an aggregator pinned this dep to rebuild (FORCE_DEP_REBUILD).
    forced_for_agg="false"
    [[ -n "${FORCE_DEP_REBUILD[${emu_id}:${tgt_id}]:-}" ]] && forced_for_agg="true"
    if [[ "${FORCE:-false}" != "true" ]] && [[ "$ver_changed" != "true" ]] \
       && [[ "$forced_for_agg" != "true" ]]; then
      per_target_marker="success-${emu_id}-${tgt_id}-${hash}"
      if echo "${MARKERS_LIST:-}" | grep -qF "$per_target_marker"; then
        echo "  SKIP $emu_id on $tgt_id (marker exists: $per_target_marker)"
        report_row "CACHED" "$emu_id" "$tgt_id" "marker already present" "${version:-${hash:0:7}}"
        report_skip_marker=$((report_skip_marker+1))
        continue
      fi
    fi
    if [[ "$forced_for_agg" == "true" ]]; then
      echo "  $emu_id on $tgt_id: marker bypass (required by an aggregator with no fallback artifacts)"
    fi

    # Resolve placeholders in extra_caches key. {arch} is kept for backwards
    # compat but {target_id} is preferred — multiple targets can share an
    # arch (arm64-legacy + arm64-modern) and must not collide on cache keys.
    resolved_cache_key=""
    if [[ -n "$extra_cache_key" ]]; then
      resolved_cache_key="${extra_cache_key//\{arch\}/$tgt_arch}"
      resolved_cache_key="${resolved_cache_key//\{target_id\}/$tgt_id}"
    fi

    # Aggregator: pass the fallback run id (if any) so build-chain.yml can
    # download libretro-cores-* from a previous successful run instead of
    # the current one (whose dep jobs may have been skipped).
    fallback_run_id="${AGG_FALLBACK_RUN[${emu_id}:${tgt_id}]:-}"

    # Build JSON entry
    entry=$(echo "$tgt_data" | jq -c \
      --arg emu_id "$emu_id" \
      --arg base_dir "$base_dir" \
      --arg version "$version" \
      --arg version_short "$version_short" \
      --arg hash "$hash" \
      --argjson chain "$chain" \
      --arg level "$level" \
      --arg artifact_type "$artifact_type" \
      --arg is_aggregator "$is_aggregator" \
      --arg extra_cache_key "$resolved_cache_key" \
      --arg extra_cache_path "$extra_cache_path" \
      --arg extra_cache_mount "$extra_cache_mount" \
      --arg extra_cache_save "$extra_cache_save" \
      --arg fallback_run_id "$fallback_run_id" \
      '{
        emulator_id: $emu_id,
        base_dir: $base_dir,
        target_id: .id,
        target_arch: .arch,
        target_runner: .runner,
        target_platform: .platform,
        target_cflags: .cflags,
        target_cxxflags: .cxxflags,
        target_source_distro: .source_distro,
        target_devices: (.devices | join(",")),
        version: $version,
        version_short: $version_short,
        hash: $hash,
        chain: $chain,
        level: $level,
        artifact_type: $artifact_type,
        is_aggregator: $is_aggregator,
        extra_cache_key: $extra_cache_key,
        extra_cache_path: $extra_cache_path,
        extra_cache_mount: $extra_cache_mount,
        extra_cache_save: $extra_cache_save,
        fallback_run_id: $fallback_run_id
      }')

    ALL_ENTRIES=$(echo "$ALL_ENTRIES" | jq --argjson e "$entry" '. + [$e]')
    report_row "BUILT" "$emu_id" "$tgt_id" "queued for build" "${version:-${hash:0:7}}"
    report_build_count=$((report_build_count+1))
  done
done

# Footer: counts tallied across all (emu × target) rows. "BUILT" here means
# "queued for a build job"; actual success/failure is reported per-job in
# the chain-*-ind / chain-*-dep summaries.
report_table_end
report_counts "Queued: $report_build_count · Cached (marker): $report_skip_marker · Skipped (power): $report_skip_power · Skipped (arch): $report_skip_arch"

# --- Step 5: Split by chain+level and output ---
any_build="false"
for chain_num in 1 2 3 4; do
  for level in ind dep; do
    chain_json=$(echo "$ALL_ENTRIES" | jq -c \
      --argjson c "$chain_num" --arg l "$level" \
      '[.[] | select(.chain == $c and .level == $l) | del(.chain, .level)]')
    count=$(echo "$chain_json" | jq 'length')
    echo "chain_${chain_num}_${level}=${chain_json}" >> "$GITHUB_OUTPUT"
    echo "Chain ${chain_num} ${level}: $count entries"
    if (( count > 0 )); then
      any_build="true"
    fi
  done
done

# Aggregators
agg_json=$(echo "$ALL_ENTRIES" | jq -c '[.[] | select(.level == "agg") | del(.chain, .level)]')
agg_count=$(echo "$agg_json" | jq 'length')
echo "aggregators=${agg_json}" >> "$GITHUB_OUTPUT"
echo "Aggregators: $agg_count entries"
if (( agg_count > 0 )); then
  any_build="true"
fi

# Output aggregated versions JSON for downstream jobs (save-trackers)
echo "versions_json=$(echo "${VERSIONS_JSON:-\{\}}" | jq -c '.')" >> "$GITHUB_OUTPUT"

echo "any_build=$any_build" >> "$GITHUB_OUTPUT"
echo "=== Done: any_build=$any_build ==="
