#!/bin/bash
# compute-chains.sh — Compute build chains from emulators.yml + devices.yml
#
# Reads emulator definitions and device list, applies power scoring,
# bin-packs emulators into 4 parallel chains by build_time, and outputs
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
EMUS_JSON=$(yq -o=json '.emulators' "$ROOT_DIR/emulators.yml")
DEVS_JSON=$(yq -o=json '.devices' "$ROOT_DIR/devices.yml")

emu_count=$(echo "$EMUS_JSON" | jq 'length')
dev_count=$(echo "$DEVS_JSON" | jq 'length')

# --- Step 1: Compute hashes (build script + emulator config entry) ---
HASHES="{}"
for (( i=0; i<emu_count; i++ )); do
  emu_id=$(echo "$EMUS_JSON" | jq -r ".[$i].id")
  script_path="$ROOT_DIR/packages/$emu_id/build.sh"
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

  # Check if version changed
  ver_changed="false"
  if [[ -n "$tracker_file" ]] && [[ -n "$version" ]]; then
    current=$(cat "$ROOT_DIR/.trackers/$tracker_file" 2>/dev/null || echo "")
    if [[ "$version" != "$current" ]]; then
      ver_changed="true"
    fi
  fi

  # Check marker
  marker_key="success-${emu_id}-${hash}"
  has_marker="false"
  if echo "${MARKERS_LIST:-}" | grep -qF "$marker_key"; then
    has_marker="true"
  fi

  # Decide
  if [[ "${FORCE:-false}" == "true" ]] || [[ "$ver_changed" == "true" ]] || [[ "$has_marker" != "true" ]]; then
    BUILDS=$(echo "$BUILDS" | jq --arg id "$emu_id" '. + {($id): true}')
    echo "  $emu_id: BUILD (force=${FORCE:-false} ver_changed=$ver_changed marker=$has_marker)"
  else
    BUILDS=$(echo "$BUILDS" | jq --arg id "$emu_id" '. + {($id): false}')
    echo "  $emu_id: SKIP (unchanged + succeeded)"
  fi
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
  artifact_type=$(echo "$emu_data" | jq -r '.artifact_type // "pkg"')
  is_aggregator=$(echo "$emu_data" | jq -r '.is_aggregator // false')
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

  for (( j=0; j<dev_count; j++ )); do
    dev_data=$(echo "$DEVS_JSON" | jq -c ".[$j]")
    dev_arch=$(echo "$dev_data" | jq -r '.arch')
    dev_power=$(echo "$dev_data" | jq -r '.power // 1')
    dev_id=$(echo "$dev_data" | jq -r '.id')

    # Power score + arch filter
    if [[ "$dev_arch" == "arm64" ]]; then
      if [[ "$true_arm" != "true" ]]; then continue; fi
      if (( dev_power < power_arm )); then
        echo "  Skipping $emu_id on $dev_id (power $dev_power < $power_arm for arm)"
        continue
      fi
    elif [[ "$dev_arch" == "amd64" ]]; then
      if [[ "$true_amd" != "true" ]]; then continue; fi
      if (( dev_power < power_amd )); then
        echo "  Skipping $emu_id on $dev_id (power $dev_power < $power_amd for amd)"
        continue
      fi
    fi

    # Resolve {arch} placeholder
    resolved_cache_key=""
    if [[ -n "$extra_cache_key" ]]; then
      resolved_cache_key="${extra_cache_key//\{arch\}/$dev_arch}"
    fi

    # Build JSON entry
    entry=$(echo "$dev_data" | jq -c \
      --arg emu_id "$emu_id" \
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
        device_id: .id,
        device_arch: .arch,
        device_runner: .runner,
        device_platform: .platform,
        device_cflags: .cflags,
        device_cxxflags: .cxxflags,
        device_name: .name,
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
