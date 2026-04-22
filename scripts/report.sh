#!/bin/bash
# report.sh — Write structured tables to $GITHUB_STEP_SUMMARY.
#
# Each job sources this file and calls the helpers below to produce a
# consistent, readable report on the GitHub Actions run page. Non-success
# rows carry a collapsible <details> block with the relevant log tail so
# the main summary stays compact.
#
# Usage:
#   source scripts/report.sh
#   report_section "Build matrix"
#   report_table "Emulator" "Target" "Decision" "Reason"
#   report_row "azahar-emu" "amd64" "SKIP" "marker cached"
#   report_row_with_log "azahar-emu" "arm64-legacy" "FAIL" "clang error" "$(tail -200 build.log)"
#   report_table_end
#
# Status glyphs are mapped to emoji so the column is scannable in the UI.

# Resolve the summary file — fall back to a sink when running locally.
REPORT_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Map a status keyword to an emoji + label cell. Keep the labels short so
# tables render without horizontal scroll.
_report_status() {
  case "${1:-}" in
    SUCCESS|OK|BUILT|APPLIED|ADDED|TRANSLATED) echo "✅ $1" ;;
    SKIP|SKIPPED|IGNORED|CACHED)               echo "⏭ $1" ;;
    FAIL|FAILED|ERROR|REJECTED)                echo "❌ $1" ;;
    WARN|WARNING|OVERSIZED|DROPPED)            echo "⚠ $1" ;;
    *)                                         echo "$1" ;;
  esac
}

# --- Section / header ------------------------------------------------------

report_section() {
  printf '\n## %s\n\n' "$1" >> "$REPORT_FILE"
}

report_note() {
  printf '%s\n\n' "$1" >> "$REPORT_FILE"
}

# --- Tables ----------------------------------------------------------------

# report_table <col1> <col2> ...
# Opens a markdown table with the given column headers.
report_table() {
  local header="|" sep="|"
  local c
  for c in "$@"; do
    header+=" ${c} |"
    sep+=" --- |"
  done
  {
    echo "$header"
    echo "$sep"
  } >> "$REPORT_FILE"
}

# report_row <status> <col1> <col2> ...
# The first positional arg is a status keyword decorated via _report_status;
# subsequent args are printed as-is.
report_row() {
  local row="| $(_report_status "$1") |"; shift
  local c
  for c in "$@"; do
    # Escape pipe characters so they don't break the table
    row+=" ${c//|/\\|} |"
  done
  echo "$row" >> "$REPORT_FILE"
}

report_table_end() {
  printf '\n' >> "$REPORT_FILE"
}

# --- Collapsible log attached to a row ------------------------------------

# After printing the row, append a <details> block with a log excerpt. Used
# for FAIL/SKIP rows where the raw log helps diagnose the outcome.
#
# Usage:
#   report_details "azahar-emu / arm64-legacy build log (tail 200)" "$(tail -200 build.log)"
report_details() {
  local title="$1" body="$2"
  {
    echo
    echo "<details><summary>$title</summary>"
    echo
    echo '```'
    echo "$body"
    echo '```'
    echo
    echo "</details>"
    echo
  } >> "$REPORT_FILE"
}

# --- Short summary line ---------------------------------------------------

# report_counts "Built: 3, Skipped: 2, Failed: 1"
report_counts() {
  printf '_%s_\n\n' "$1" >> "$REPORT_FILE"
}
