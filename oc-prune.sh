#!/usr/bin/env bash
# oc-prune.sh – tidy up sessions, scanning with "opencode session list" per directory
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/oc-lib.sh"
oc_init
oc_args "$@"

CUTOFF=$(( ($(date +%s) - DAYS * 86400) * 1000 ))

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

all_sessions() {
  local i=0 x d json stats n_own n_foreign n_kill
  local -a dirs=()
  for x in "$ROOT" "$ROOT"/*/; do
    if [[ -d "$x" ]]; then dirs+=("$x"); fi
  done
  for d in "${dirs[@]}"; do
    (( ++i ))
    json=$( (cd "$d" && opencode session list --format json 2>/dev/null) || true )
    stats=$(printf '%s' "$json" | jq -r --arg d "${d%/}" --argjson c "$CUTOFF" --argjson m "$MIN" '
      (if type == "array" then . else [] end) as $all
      | ($all | map(select(.directory == $d)) | sort_by(-.updated)) as $s
      | [ ($s | length),
          (($all | length) - ($s | length)),
          ($s[$m:] | map(select(.updated < $c)) | length) ]
      | @tsv' 2>/dev/null) || stats=""
    read -r n_own n_foreign n_kill <<< "$stats"
    printf 'scan [%d/%d] %-45s %6s sessions  %6s foreign  %6s deletable\n' \
      "$i" "${#dirs[@]}" "${d%/}" "${n_own:-0}" "${n_foreign:-0}" "${n_kill:-0}" >&2
    if [[ -n "$json" ]]; then printf '%s\n' "$json"; fi
  done | jq -s 'add // [] | unique_by(.id)'
}

db_report
SESSIONS=$(all_sessions)
SESSIONS=$(oc_augment_missing "$SESSIONS")
SESSIONS=$(oc_filter_only "$SESSIONS")
db_sizes
print_table "$SESSIONS"
run_apply "$SESSIONS"
