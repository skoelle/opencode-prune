# oc-lib.sh – shared reporting and deletion logic for oc-prune.sh / oc-prune-db.sh
# The opencode database is only read with "sqlite3 -readonly" – one exception:
# run_vacuum (--vacuum) opens it writable for the checkpoint and VACUUM INTO.
# Otherwise nothing is written except our own size cache.

declare -a OC_MISSING_DIRS=()
APPLY=0
OC_VACUUM=0
OC_MISSING='[]'
OC_DATA_NOTE='-'
OC_T_EV=0
OC_T_PT=0
OC_T_MSG=0
OC_T_SES=0
OC_ORPH_N=0
OC_ORPH_B=0

# read .env first (only variables that are still unset), then apply defaults
oc_init() {
  local dir envfile
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  envfile=${ENV_FILE:-"$dir/.env"}
  load_env "$envfile"
  ROOT=${ROOT:-$HOME/Code}
  DAYS=${DAYS:-30}
  MIN=${MIN:-3}
  BACKUP=${BACKUP:-$HOME/opencode-export}
  DB=${DB:-$HOME/.local/share/opencode/opencode.db}
  ONLY=${ONLY:-}
  SIZE_CACHE=${SIZE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/oc-prune/db-data.tsv}
}

load_env() {
  local f=$1 line k v
  [[ -r "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|\#*) continue ;; esac
    [[ "$line" == *"="* ]] || continue
    k=${line%%=*}
    v=${line#*=}
    k=${k//[[:space:]]/}
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    if [[ "$v" == \"*\" ]]; then v=${v:1:-1}; fi
    if [[ "$v" == \'*\' ]]; then v=${v:1:-1}; fi
    case "$k" in
      ROOT|DAYS|MIN|BACKUP|DB|ONLY|SIZES|SIZE_CACHE)
        if [[ -z "${!k:-}" ]]; then printf -v "$k" '%s' "$v"; fi ;;
    esac
  done < "$f"
}

sql()  { sqlite3 -readonly -cmd 'PRAGMA cache_size=8000;' "$DB" "$1"; }
sqlj() { sqlite3 -readonly -json -cmd 'PRAGMA cache_size=8000;' "$DB" "$1"; }

# writable access – only used by run_vacuum, see AGENTS.md
sqlw() { sqlite3 -cmd 'PRAGMA cache_size=8000;' "$DB" "$1"; }

oc_usage() {
  cat <<EOF
Usage: $0 [--apply] [--vacuum]

  (no option)   dry run: report + table, nothing is modified
  --apply       export each session to \$BACKUP, then delete it
  --vacuum      compact the database (opencode must be closed)
                needs free disk space of at least the database size

Configuration: environment variable -> .env -> default
  ROOT DAYS MIN BACKUP DB ONLY SIZES SIZE_CACHE
EOF
}

# flags – both entry scripts parse them the same way
oc_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --apply)   APPLY=1 ;;
      --vacuum)  OC_VACUUM=1 ;;
      -h|--help) oc_usage; exit 0 ;;
      *) printf 'Unknown option: %s (try %s --help)\n' "$a" "$0" >&2
         return 1 ;;
    esac
  done
}

fmt_b() {
  awk -v b="${1:-0}" 'BEGIN{
    if   (b >= 1073741824) printf "%.2f GiB", b/1073741824
    else if (b >= 1048576) printf "%.1f MiB", b/1048576
    else if (b >= 1024)    printf "%.1f KiB", b/1024
    else                   printf "%d B", b }'
}

db_readable() { command -v sqlite3 >/dev/null 2>&1 && [[ -r "$DB" ]]; }

# header: file size, WAL, free pages, session count, missing directories
db_report() {
  : > "$TMP/sizes.tsv"
  OC_MISSING='[]'
  OC_MISSING_DIRS=()

  if ! db_readable; then
    printf 'Database not readable: %s (no DB report)\n' "$DB" >&2
    return 0
  fi

  local prg pages psize freelist file_b=0 wal_b=0 db_b free_b
  prg=$(sql "SELECT page_count||'|'||page_size||'|'||freelist_count
             FROM pragma_page_count, pragma_page_size, pragma_freelist_count;") || prg=''
  if [[ -z "$prg" ]]; then
    printf 'Database not readable: %s (query failed)\n' "$DB" >&2
    return 0
  fi
  IFS='|' read -r pages psize freelist <<< "$prg"
  db_b=$(( ${pages:-0} * ${psize:-0} ))
  free_b=$(( ${freelist:-0} * ${psize:-0} ))
  [[ -f "$DB" ]] && file_b=$(stat -c%s "$DB")
  [[ -f "$DB-wal" ]] && wal_b=$(stat -c%s "$DB-wal")

  printf 'Database (read-only): %s\n' "$DB"
  printf '  file %s | WAL %s | freelist %s (%s %%)\n' \
    "$(fmt_b "$file_b")" "$(fmt_b "$wal_b")" "$(fmt_b "$free_b")" \
    "$(awk -v a="$free_b" -v b="$db_b" 'BEGIN{printf "%.1f", (b ? 100*a/b : 0)}')"
  if (( free_b > 0 )); then
    printf '  VACUUM would give %s back to the filesystem (opencode never shrinks the file)\n' \
      "$(fmt_b "$free_b")"
  fi

  local cnt n_all n_sub
  cnt=$(sql "SELECT count(*)||'|'||coalesce(sum(parent_id IS NOT NULL),0) FROM session;") || cnt=''
  IFS='|' read -r n_all n_sub <<< "${cnt:-0|0}"
  printf '  sessions %s (+ %s subagents)\n' "$(( ${n_all:-0} - ${n_sub:-0} ))" "${n_sub:-0}"

  local d n sub line
  local -a lines=()
  while IFS='|' read -r d n sub; do
    [[ -n "$d" ]] || continue
    if [[ ! -d "$d" ]]; then
      OC_MISSING_DIRS+=("$d")
      line=$(printf '    %-48s %4s sessions' "$d" "$n")
      if [[ "${sub:-0}" -gt 0 ]]; then
        line="$line (+$sub subagents)"
      fi
      lines+=("$line")
    fi
  done < <(sql "SELECT directory||'|'||sum(parent_id IS NULL)||'|'||sum(parent_id IS NOT NULL)
                FROM session GROUP BY directory ORDER BY count(*) DESC;")

  if ((${#lines[@]})); then
    printf '  Missing directories:\n'
    printf '%s\n' "${lines[@]}"
    OC_MISSING=$(printf '%s\n' "${OC_MISSING_DIRS[@]}" | jq -R . | jq -s .)
  else
    printf '  Missing directories: none\n'
  fi
}

# add sessions whose directory is gone – a directory scan can never find them
oc_augment_missing() {
  local sessions=$1 extra='[]'
  [[ -n "$sessions" ]] || sessions='[]'
  if db_readable && ((${#OC_MISSING_DIRS[@]})); then
    extra=$(sqlj "SELECT id, directory, time_updated AS updated
                  FROM session WHERE parent_id IS NULL;") || extra='[]'
    printf '%s' "$sessions" | jq -c --argjson all "${extra:-[]}" --argjson miss "$OC_MISSING" '
      . as $s
      | ($all
         | map(select(.directory as $d | ($miss | index($d)) != null))
         | map(select(.id as $i | ($s | map(.id) | index($i)) == null))) as $e
      | ($s + $e) | unique_by(.id)'
  else
    printf '%s\n' "$sessions"
  fi
}

# scope filter ONLY: work on this directory (and everything below it) only
oc_filter_only() {
  local sessions=$1
  if [[ -z "$ONLY" ]]; then
    printf '%s\n' "$sessions"
    return 0
  fi
  printf 'Only directory: %s\n' "$ONLY" >&2
  printf '%s' "$sessions" | jq -c --arg o "$ONLY" '
    map(select(.directory == $o or (.directory | startswith($o + "/"))))'
}

# table sizes, orphan events and data per directory (cached)
db_sizes() {
  db_readable || return 0

  if [[ "${SIZES:-1}" == "0" ]]; then
    OC_DATA_NOTE='skipped (SIZES=0)'
  else
    local key raw
    # key uses count and time_created only: it stays stable while opencode is
    # working (time_updated keeps changing then) but a new or deleted session
    # still triggers a recomputation
    key=$(sql "SELECT count(*)||'/'||coalesce(max(time_created),0) FROM session;") || key=''
    if [[ -n "$key" && -r "$SIZE_CACHE" && "$(head -n1 "$SIZE_CACHE")" == "key=$key" ]]; then
      raw="$SIZE_CACHE"
      OC_DATA_NOTE="cached (snapshot $key)"
    else
      printf '  computing DB sizes (table pages + event data, ~1-2 min) …\n'
      if oc_compute_raw > "$TMP/raw.tsv" && [[ -s "$TMP/raw.tsv" ]]; then
        mkdir -p "$(dirname "$SIZE_CACHE")"
        { printf 'key=%s\n' "${key:-0}"; cat "$TMP/raw.tsv"; } > "$SIZE_CACHE.tmp"
        mv "$SIZE_CACHE.tmp" "$SIZE_CACHE"
        raw="$TMP/raw.tsv"
        OC_DATA_NOTE="computed and cached (snapshot ${key:-0})"
      else
        printf '  could not compute DB sizes\n' >&2
        OC_DATA_NOTE='unavailable'
        raw=''
      fi
    fi

    if [[ -n "$raw" ]]; then
      oc_parse_raw "$raw"
    fi
  fi

  printf '  event %s | part %s | message %s | session %s\n' \
    "$(fmt_b "$OC_T_EV")" "$(fmt_b "$OC_T_PT")" "$(fmt_b "$OC_T_MSG")" "$(fmt_b "$OC_T_SES")"
  printf '  orphan events %s (%s) | data per directory: %s\n' \
    "$OC_ORPH_N" "$(fmt_b "$OC_ORPH_B")" "$OC_DATA_NOTE"
}

# one full scan of the event table plus a small part scan
oc_compute_raw() {
  local t
  t=$(sql "SELECT coalesce(sum(CASE WHEN name LIKE 'event%'   THEN pgsize ELSE 0 END),0)||'|'||
                  coalesce(sum(CASE WHEN name LIKE 'part%'    THEN pgsize ELSE 0 END),0)||'|'||
                  coalesce(sum(CASE WHEN name LIKE 'message%' THEN pgsize ELSE 0 END),0)||'|'||
                  coalesce(sum(CASE WHEN name LIKE 'session%' THEN pgsize ELSE 0 END),0)
           FROM dbstat;") || return 1
  printf 'tables\t%s\n' "$t"

  sql "SELECT coalesce(s.directory,'')||'|'||count(*)||'|'||sum(length(e.data))
       FROM event e LEFT JOIN session s ON s.id = e.aggregate_id
       GROUP BY s.directory;" |
  while IFS='|' read -r d n b; do
    if [[ -n "$d" ]]; then
      printf 'ev\t%s\t%s\n' "$d" "$b"
    else
      printf 'orph\t%s\t%s\n' "${n:-0}" "${b:-0}"
    fi
  done

  sql "SELECT s.directory||'|'||sum(length(p.data))
       FROM part p JOIN session s ON s.id = p.session_id
       GROUP BY s.directory;" |
  while IFS='|' read -r d b; do
    printf 'pt\t%s\t%s\n' "$d" "$b"
  done
}

oc_parse_raw() {
  local raw=$1 tables orph
  tables=$(awk -F'\t' '$1=="tables"{print $2}' "$raw")
  IFS='|' read -r OC_T_EV OC_T_PT OC_T_MSG OC_T_SES <<< "${tables:-0|0|0|0}"
  orph=$(awk -F'\t' '$1=="orph"{print $2"|"$3}' "$raw")
  IFS='|' read -r OC_ORPH_N OC_ORPH_B <<< "$orph"
  OC_ORPH_N=${OC_ORPH_N:-0}
  OC_ORPH_B=${OC_ORPH_B:-0}

  awk -F'\t' '
    $1 == "ev" { e[$2] = $3 + 0; k[$2] = 1 }
    $1 == "pt" { p[$2] = $3 + 0; k[$2] = 1 }
    END { for (d in k) printf "%s\t%.1f\n", d, (e[d] + p[d]) / 1048576 }
  ' "$raw" > "$TMP/sizes.tsv"
}

# all top-level sessions (subagents are left out, like "opencode session list")
db_sessions() {
  local out
  out=$(sqlj "SELECT id, directory, time_updated AS updated
              FROM session WHERE parent_id IS NULL;") || out=''
  printf '%s\n' "${out:-[]}"
}

print_table() {
  local sessions=$1

  printf '\nRule: older than %s days, keep at least %s per directory\n' "$DAYS" "$MIN"
  printf 'Rule: missing directory, keep nothing\n'
  printf 'Cutoff: %s\n\n' "$(date -d "-$DAYS days" +%F)"
  printf '%-45s %6s %11s %11s %8s %9s %7s\n' \
    DIRECTORY COUNT NEWEST OLDEST DELETE MB NOTE

  printf '%s' "$sessions" | jq -r \
    --argjson c "$CUTOFF" --argjson m "$MIN" \
    --argjson miss "$OC_MISSING" --arg root "$ROOT" \
    --rawfile mb "$TMP/sizes.tsv" '
    (if ($mb | length) > 0
     then ($mb | split("\n") | map(select(length > 0) | split("\t")
           | {key: .[0], value: (.[1] | tonumber)}) | from_entries)
     else {} end) as $sz
    | group_by(.directory)[]
    | sort_by(-.updated) as $s
    | ($s[0].directory) as $d
    | [ $d,
        ($s | length),
        ($s[0].updated / 1000 | floor | strftime("%F")),
        ($s[-1].updated / 1000 | floor | strftime("%F")),
        (if ($miss | index($d)) then ($s | length)
         else ($s[$m:] | map(select(.updated < $c)) | length) end),
        (if $sz[$d] then ($sz[$d] | tostring) else "-" end),
        (if ($miss | index($d)) then "missing"
         elif ($d == $root or ($d | startswith($root + "/"))) then ""
         else "outside" end) ]
    | @tsv' |
    awk -F'\t' '{printf "%-45s %6s %11s %11s %8s %9s %7s\n",$1,$2,$3,$4,$5,$6,$7}'

  local tot_n=0 tot_dirs=0 tot_k=0
  read -r tot_n tot_dirs tot_k < <(printf '%s' "$sessions" | jq -r \
    --argjson c "$CUTOFF" --argjson m "$MIN" --argjson miss "$OC_MISSING" '
    group_by(.directory)
    | [ (map(length) | add // 0),
        length,
        (map((.[0].directory) as $d
             | if ($miss | index($d)) then length
               else (sort_by(-.updated) | .[$m:] | map(select(.updated < $c)) | length)
               end) | add // 0) ]
    | @tsv') || true

  printf '\nTotal: %s sessions in %s directories, %s deletable\n' \
    "${tot_n:-0}" "${tot_dirs:-0}" "${tot_k:-0}"
}

run_apply() {
  local sessions=$1

  if (( APPLY == 0 )); then
    if (( OC_VACUUM == 0 )); then
      printf '\nDry run. To delete: %s --apply\n' "$0"
      exit 0
    fi
    # --vacuum without --apply: nothing is deleted, the file is compacted only
    run_vacuum
    exit 0
  fi

  # -x: exact process name "opencode" – "-f opencode" would also match
  # "vim opencode.json" and our own command line (…/opencode-prune/…)
  pgrep -u "$USER" -x opencode >/dev/null && {
    echo "opencode is still running, please quit it first." >&2; exit 1; }

  printf 'Export to: %s\n' "$BACKUP"
  mkdir -p "$BACKUP" 2>/dev/null || {
    echo "Cannot create backup directory: $BACKUP" >&2; exit 1; }

  printf '%s' "$sessions" | jq -r \
    --argjson c "$CUTOFF" --argjson m "$MIN" --argjson miss "$OC_MISSING" '
    group_by(.directory)[]
    | sort_by(-.updated) as $s
    | ($s[0].directory) as $d
    | (if ($miss | index($d)) then $s
       else ($s[$m:] | map(select(.updated < $c))) end)[]
    | [.id, .directory] | @tsv' > "$TMP/targets"

  # the session table has no CASCADE on parent_id: subagent sessions of
  # missing directories are exported and deleted first
  : > "$TMP/targets_sub"
  if ((${#OC_MISSING_DIRS[@]})); then
    local d id dir
    while IFS='|' read -r id dir; do
      for d in "${OC_MISSING_DIRS[@]}"; do
        if [[ "$dir" != "$d" ]]; then continue; fi
        if [[ -n "$ONLY" && "$dir" != "$ONLY" && "$dir" != "$ONLY"/* ]]; then continue; fi
        printf '%s\t%s\n' "$id" "$dir" >> "$TMP/targets_sub"
      done
    done < <(sql "SELECT id||'|'||directory FROM session WHERE parent_id IS NOT NULL;")
  fi

  local n i=0 f out
  n=$(( $(awk 'END{print NR}' "$TMP/targets_sub") + $(awk 'END{print NR}' "$TMP/targets") ))

  for f in "$TMP/targets_sub" "$TMP/targets"; do
    while IFS=$'\t' read -r id dir; do
      [[ -n "$id" ]] || continue
      (( ++i ))
      out="$BACKUP/$(basename "$dir")"
      mkdir -p "$out"
      printf 'deleting [%d/%d] %s (%s) … ' "$i" "$n" "$id" "$dir" >&2
      opencode export "$id" > "$out/$id.json"
      if [[ ! -s "$out/$id.json" ]]; then
        echo "Empty export: $id" >&2
        exit 1
      fi
      opencode session delete "$id"
      echo "deleted" >&2
    done < "$f"
  done

  # freed pages stay inside the file: auto_vacuum is OFF in the opencode DB
  # and opencode never runs a VACUUM itself
  local free_b
  free_b=$(sql "SELECT freelist_count * page_size
                FROM pragma_freelist_count, pragma_page_size;") || free_b=0
  free_b=${free_b:-0}
  if (( free_b > 0 )); then
    printf '\nFreelist after delete: %s – the file itself does not shrink\n' \
      "$(fmt_b "$free_b")"
    if (( OC_VACUUM )); then
      run_vacuum
    else
      printf 'Reclaim it with: %s --vacuum   (opencode must be closed)\n' "$0"
    fi
  elif (( OC_VACUUM )); then
    run_vacuum
  fi
}

# compact the database – the only place where it is opened writable.
# VACUUM INTO instead of a plain VACUUM: a plain VACUUM needs up to twice the
# file size as free space, VACUUM INTO only needs the compacted copy.
run_vacuum() {
  printf '\nVacuum:\n'
  if ! db_readable; then
    printf '  sqlite3 or %s not available\n' "$DB" >&2
    return 1
  fi

  # -x: exact process name, "-f opencode" would match our own command line
  pgrep -u "$USER" -x opencode >/dev/null && {
    echo "opencode is still running, please quit it first." >&2; exit 1; }

  local file_b avail tmp busy chk after
  file_b=$(stat -c%s "$DB")
  avail=$(df -B1 --output=avail "$(dirname "$DB")" | tail -n1 | tr -d ' ')
  tmp="$DB.vac"

  printf '  before %s | free on disk %s\n' \
    "$(fmt_b "$file_b")" "$(fmt_b "${avail:-0}")"
  if [[ "${avail:-0}" -lt "$file_b" ]]; then
    printf '  Not enough free space: the compacted copy can be as large as the\n' >&2
    printf '  database itself (%s), only %s is free.\n' \
      "$(fmt_b "$file_b")" "$(fmt_b "${avail:-0}")" >&2
    return 1
  fi
  if [[ -e "$tmp" ]]; then
    printf '  Refusing: %s already exists – remove it first.\n' "$tmp" >&2
    return 1
  fi

  busy=$(sqlw 'PRAGMA wal_checkpoint(TRUNCATE);') || busy=''
  if [[ "${busy%%|*}" != "0" ]]; then
    printf '  WAL checkpoint failed (%s) – is opencode really closed?\n' "$busy" >&2
    return 1
  fi
  if [[ -f "$DB-wal" && "$(stat -c%s "$DB-wal")" -gt 0 ]]; then
    printf '  WAL still %s after checkpoint – aborting, nothing is changed.\n' \
      "$(fmt_b "$(stat -c%s "$DB-wal")")" >&2
    return 1
  fi

  printf '  integrity check … '
  chk=$(sqlw 'PRAGMA integrity_check;') || chk=''
  if [[ "$chk" != "ok" ]]; then
    printf 'FAILED (%s) – not compacting a damaged database.\n' "$chk" >&2
    return 1
  fi
  echo ok

  printf '  VACUUM INTO %s … ' "$(basename "$tmp")"
  sqlw "VACUUM INTO '$tmp';" >/dev/null
  echo done

  chk=$(sqlite3 -readonly "$tmp" 'PRAGMA integrity_check;') || chk=''
  if [[ "$chk" != "ok" ]]; then
    printf '  integrity check of the new file FAILED (%s) – original untouched.\n' \
      "$chk" >&2
    rm -f "$tmp"
    return 1
  fi

  # the old WAL/SHM belong to the old file and must not survive the swap
  mv -f "$tmp" "$DB"
  rm -f "$DB-wal" "$DB-shm"
  sqlw 'PRAGMA journal_mode=WAL;' >/dev/null || true

  after=$(stat -c%s "$DB")
  printf '  after  %s (freed %s)\n' \
    "$(fmt_b "$after")" "$(fmt_b "$(( file_b - after ))")"
}
