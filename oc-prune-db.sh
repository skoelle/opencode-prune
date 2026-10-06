#!/usr/bin/env bash
# oc-prune-db.sh – tidy up sessions, scanning the opencode database directly
# (one readonly SELECT instead of one opencode call per directory)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/oc-lib.sh"
oc_init
oc_args "$@"

CUTOFF=$(( ($(date +%s) - DAYS * 86400) * 1000 ))

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! db_readable; then
  echo "sqlite3 or $DB not available – use oc-prune.sh" >&2
  exit 1
fi

db_report

SCAN_START=$(date +%s)
SESSIONS=$(db_sessions)
SESSIONS=$(oc_augment_missing "$SESSIONS")
SESSIONS=$(oc_filter_only "$SESSIONS")
printf 'scan (db): %s sessions without subagents in %s s\n' \
  "$(printf '%s' "$SESSIONS" | jq 'length')" "$(( $(date +%s) - SCAN_START ))"

db_sizes
print_table "$SESSIONS"
run_apply "$SESSIONS"
