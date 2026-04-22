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

# --- Step 4: Build matrix entries, accumulate into ALL_ENTRIES with chain/level fields ---
ALL_ENTRIES="[]"

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
      if [[ "$true_arm" != "true" ]]; then continue; fi
      if (( tgt_power < power_arm )); then
        echo "  Skipping $emu_id on $tgt_id (max power $tgt_power < $power_arm for arm)"
        continue
      fi
    elif [[ "$tgt_arch" == "amd64" ]]; then
      if [[ "$true_amd" != "true" ]]; then continue; fi
      if (( tgt_power < power_amd )); then
        echo "  Skipping $emu_id on $tgt_id (max power $tgt_power < $power_amd for amd)"
        continue
      fi
    fi

    # Skip this target if it already has a success marker for the exact
    # (emu, target, hash) triple — unless we were forced / version changed.
    if [[ "${FORCE:-false}" != "true" ]] && [[ "$ver_changed" != "true" ]]; then
      per_target_marker="success-${emu_id}-${tgt_id}-${hash}"
      if echo "${MARKERS_LIST:-}" | grep -qF "$per_target_marker"; then
        echo "  SKIP $emu_id on $tgt_id (marker exists: $per_target_marker)"
        continue
      fi
    fi

    # Resolve placeholders in extra_caches key. {arch} is kept for backwards
    # compat but {target_id} is preferred — multiple targets can share an
    # arch (arm64-legacy + arm64-modern) and must not collide on cache keys.
    resolved_cache_key=""
    if [[ -n "$extra_cache_key" ]]; then
      resolved_cache_key="${extra_cache_key//\{arch\}/$tgt_arch}"
      resolved_cache_key="${resolved_cache_key//\{target_id\}/$tgt_id}"
    fi

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
        extra_cache_save: $extra_cache_save
      }')

    ALL_ENTRIES=$(echo "$ALL_ENTRIES" | jq --argjson e "$entry" '. + [$e]')
  done
done

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
