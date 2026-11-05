# oc-lib.sh – shared reporting and deletion logic for oc-prune.sh / oc-prune-db.sh
# The opencode database is only read with "sqlite3 -readonly" – the exceptions are
# the --vacuum path (run_vacuum opens it writable for the checkpoint and
# VACUUM INTO, and run_backup does the same checkpoint when BACKUP_REMOTE is set)
# and the V1 cleanup path (run_cleanup_legacy / the targeted legacy delete in
# run_apply remove stale V1 rows after opencode v2 migrated them). Writes go to
# $BACKUP (exports/local backup) and $BACKUP_REMOTE (full database backup);
# otherwise only our size cache is written.

declare -a OC_MISSING_DIRS=()
APPLY=0
OC_VACUUM=0
OC_CLEANUP_LEGACY=0
OC_BACKUP=1
OC_MISSING='[]'
OC_DATA_NOTE='-'
OC_T_EV=0
OC_T_PT=0
OC_T_MSG=0
OC_T_SES=0
OC_ORPH_N=0
OC_ORPH_B=0
OC_VAC_LIVE=0
OC_VAC_MARGIN=0
OC_VAC_NEED=0

# detected database schema (see oc_schema_init)
OC_SCHEMA_INIT=0
OC_SCHEMA='none'          # v1 | v2 | mixed | none
OC_MIGRATION=''           # kv migration.v1-v2 phase: completed | sessions | ''
OC_SESSION_SRC=''         # SQL subquery with id, directory, time_created, time_updated, parent_id, version
OC_LEGACY=0               # v2 store that still keeps the V1 tables
OC_HAS_V1=0
OC_HAS_V2=0
OC_HAS_SESSION_MESSAGE=0
OC_HAS_SESSION_PART=0

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
  BACKUP_REMOTE=${BACKUP_REMOTE:-}
  DB=${DB:-$HOME/.local/share/opencode/opencode.db}
  ONLY=${ONLY:-}
  SIZE_CACHE=${SIZE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/oc-prune/db-data.tsv}
  OC_BIN=${OC_BIN:-opencode}
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
      ROOT|DAYS|MIN|BACKUP|BACKUP_REMOTE|DB|ONLY|SIZES|SIZE_CACHE|OC_BIN)
        if [[ -z "${!k:-}" ]]; then printf -v "$k" '%s' "$v"; fi ;;
    esac
  done < "$f"
}

sql()  { sqlite3 -readonly -cmd 'PRAGMA cache_size=8000;' "$DB" "$1"; }
sqlj() { sqlite3 -readonly -json -cmd 'PRAGMA cache_size=8000;' "$DB" "$1"; }

# writable access – used by run_vacuum and the V1 cleanup (run_cleanup_legacy /
# the targeted legacy delete in run_apply), see AGENTS.md
sqlw() { sqlite3 -cmd 'PRAGMA cache_size=8000;' "$DB" "$1"; }

oc_usage() {
  cat <<EOF
Usage: $0 [--apply] [--vacuum] [--cleanup-legacy] [--no-backup]

  (no option)   dry run: report + table, nothing is modified
  --apply       export each session to \$BACKUP, then delete it
  --vacuum      full backup of the database, then compact it
                (opencode must be closed, needs the expected compacted size free;
                in a terminal it can compact via \$BACKUP if the disk is too small)
  --cleanup-legacy
                full backup, then delete the stale V1 rows that remain after
                opencode v2 migrated the database (V1 sessions without a
                session_v2 counterpart). Destructive, like --vacuum.
  --no-backup   with --vacuum/--cleanup-legacy: work without the backup copy

  BACKUP_REMOTE  [user@]host:/absolute/path – with --vacuum/--cleanup-legacy the
                 full database copy is uploaded there via ssh/rsync instead of
                 \$BACKUP

Configuration: environment variable -> .env -> default
  ROOT DAYS MIN BACKUP BACKUP_REMOTE DB ONLY SIZES SIZE_CACHE OC_BIN
EOF
}

# flags – both entry scripts parse them the same way
oc_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --apply)          APPLY=1 ;;
      --vacuum)         OC_VACUUM=1 ;;
      --cleanup-legacy) OC_CLEANUP_LEGACY=1 ;;
      --no-backup)      OC_BACKUP=0 ;;
      -h|--help)        oc_usage; exit 0 ;;
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

# detect which schema the database uses. V1 stores sessions in "session" with
# turns in "message"/"part"; V2 keeps the legacy tables after an in-place upgrade
# and moves the live data to "session_v2"/"session_message"/"session_part". The
# migration state lives in "kv" under "migration.v1-v2". Sets OC_SCHEMA, the
# table flags and OC_SESSION_SRC (the active session source for all queries).
oc_schema_init() {
  OC_SCHEMA_INIT=1
  OC_SCHEMA=none
  OC_MIGRATION=''
  OC_LEGACY=0
  OC_HAS_V1=0
  OC_HAS_V2=0
  OC_HAS_SESSION_MESSAGE=0
  OC_HAS_SESSION_PART=0
  OC_SESSION_SRC=''

  db_readable || return 0

  local n
  n=$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='session';") || return 0
  (( n )) && OC_HAS_V1=1
  n=$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='session_v2';") || true
  (( ${n:-0} )) && OC_HAS_V2=1
  n=$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='session_message';") || true
  (( ${n:-0} )) && OC_HAS_SESSION_MESSAGE=1
  n=$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='session_part';") || true
  (( ${n:-0} )) && OC_HAS_SESSION_PART=1

  if (( OC_HAS_V2 )); then
    n=$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='kv';") || true
    if (( ${n:-0} )); then
      OC_MIGRATION=$(sql "SELECT coalesce(json_extract(value, '\$.phase'), '') FROM kv WHERE key='migration.v1-v2' LIMIT 1;") \
        || OC_MIGRATION=''
    fi
    if (( OC_HAS_V1 )) && [[ "$OC_MIGRATION" != "completed" ]]; then
      OC_SCHEMA=mixed
    else
      OC_SCHEMA=v2
    fi
  elif (( OC_HAS_V1 )); then
    OC_SCHEMA=v1
  else
    return 0
  fi

  (( OC_HAS_V1 && OC_HAS_V2 )) && OC_LEGACY=1

  case "$OC_SCHEMA" in
    v1)
      OC_SESSION_SRC="SELECT id, directory, time_created, time_updated, parent_id, version FROM session" ;;
    v2)
      OC_SESSION_SRC="SELECT id, directory, time_created, time_updated, parent_id, version FROM session_v2" ;;
    mixed)
      OC_SESSION_SRC="SELECT id, directory, time_created, time_updated, parent_id, version FROM session_v2
        UNION ALL
        SELECT id, directory, time_created, time_updated, parent_id, version FROM session s
        WHERE NOT EXISTS (SELECT 1 FROM session_v2 v WHERE v.id = s.id)" ;;
  esac
}

# "-x" matches the exact process name – "-f opencode" would also match
# "vim opencode.json" and our own command line (.../opencode-prune/...).
# opencode v2 may be installed as "opencode2" as well as "opencode".
oc_guard_closed() {
  local b bin
  bin=${OC_BIN:-opencode}
  for b in opencode opencode2 "${bin##*/}"; do
    [[ -n "$b" ]] || continue
    if pgrep -u "$USER" -x "$b" >/dev/null; then
      echo "$b is still running, please quit it first." >&2
      exit 1
    fi
  done
  return 0
}

# schema-aware export command: v1 has a top-level "export", v2 only "session export"
oc_export_session() {
  if [[ "$OC_SCHEMA" == "v2" ]]; then
    "${OC_BIN:-opencode}" session export "$1"
  else
    "${OC_BIN:-opencode}" export "$1"
  fi
}

# installed CLI version – read once, no DB access. Last non-empty line, so a
# banner an older build prints before the number does not leak in.
OC_CLI_VERSION=''
oc_cli_version() {
  if [[ -z "$OC_CLI_VERSION" ]]; then
    OC_CLI_VERSION=$("${OC_BIN:-opencode}" --version 2>/dev/null \
      | awk 'NF { last = $0 } END { print last }')
    OC_CLI_VERSION=${OC_CLI_VERSION:-unknown}
  fi
  printf '%s' "$OC_CLI_VERSION"
}

oc_free_bytes() { df -B1 --output=avail "$1" | tail -n1 | tr -d ' '; }

# header: file size, WAL, free pages, session count, missing directories
db_report() {
  : > "$TMP/sizes.tsv"
  OC_MISSING='[]'
  OC_MISSING_DIRS=()

  if ! db_readable; then
    printf 'Database not readable: %s (no DB report)\n' "$DB" >&2
    return 0
  fi

  (( OC_SCHEMA_INIT )) || oc_schema_init

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
  case "$OC_SCHEMA" in
    v1)    printf '  schema v1 (session/message/part)\n' ;;
    v2)    printf '  schema v2 (session_v2/session_message/session_part)\n' ;;
    mixed) printf '  schema v2, V1 migration still running (%s)\n' "${OC_MIGRATION:-no state}" ;;
    *)     printf '  schema unknown (no session or session_v2 table)\n' ;;
  esac
  if (( OC_LEGACY )); then
    local lo
    lo=$(sql "SELECT count(*) FROM session s
              WHERE NOT EXISTS (SELECT 1 FROM session_v2 v WHERE v.id = s.id);") || lo=0
    printf '  V1 rows %s (left over by the v2 migration; cleaned with --cleanup-legacy)\n' "${lo:-0}"
  fi

  local cli sver sn cli_major=''
  cli=$(oc_cli_version)
  sver=''; sn=0
  if [[ -n "$OC_SESSION_SRC" ]]; then
    sver=$(sql "SELECT coalesce(max(version),'') FROM ($OC_SESSION_SRC);") || sver=''
    sn=$(sql "SELECT count(distinct version) FROM ($OC_SESSION_SRC);") || sn=0
  fi
  printf '  opencode %s (CLI) | sessions up to %s' "$cli" "${sver:-unknown}"
  if [[ "${sn:-0}" -gt 1 ]]; then printf ' (%s versions)' "$sn"; fi
  printf '\n'
  if [[ "$cli" =~ ^([0-9]+) ]]; then cli_major=${BASH_REMATCH[1]}; fi
  if [[ -n "$cli_major" ]]; then
    if [[ "$OC_SCHEMA" == "v2" && "$cli_major" -lt 2 ]]; then
      printf '  WARNING: database is v2 but the CLI is v1 – set OC_BIN to the v2 binary\n'
    elif [[ "$OC_SCHEMA" == "v1" && "$cli_major" -ge 2 ]]; then
      printf '  note: database is still v1; starting opencode v2 migrates it in place\n'
    fi
  fi

  printf '  file %s | WAL %s | freelist %s (%s %%)\n' \
    "$(fmt_b "$file_b")" "$(fmt_b "$wal_b")" "$(fmt_b "$free_b")" \
    "$(awk -v a="$free_b" -v b="$db_b" 'BEGIN{printf "%.1f", (b ? 100*a/b : 0)}')"
  if (( free_b > 0 )); then
    printf '  VACUUM would give %s back to the filesystem (opencode never shrinks the file)\n' \
      "$(fmt_b "$free_b")"
  fi

  local cnt n_all n_sub
  cnt=$(sql "SELECT count(*)||'|'||coalesce(sum(parent_id IS NOT NULL),0) FROM ($OC_SESSION_SRC);") || cnt=''
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
                FROM ($OC_SESSION_SRC) GROUP BY directory ORDER BY count(*) DESC;")

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
                  FROM ($OC_SESSION_SRC) WHERE parent_id IS NULL;") || extra='[]'
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
  (( OC_SCHEMA_INIT )) || oc_schema_init

  if [[ "${SIZES:-1}" == "0" ]]; then
    OC_DATA_NOTE='skipped (SIZES=0)'
  else
    local key raw
    # key uses count and time_created only: it stays stable while opencode is
    # working (time_updated keeps changing then) but a new or deleted session
    # still triggers a recomputation. Schema and the V1 leftovers are part of
    # the key so a v1 -> v2 upgrade invalidates the cache.
    local lo=0
    key=$(sql "SELECT count(*)||'/'||coalesce(max(time_created),0) FROM ($OC_SESSION_SRC);") || key=''
    if (( OC_LEGACY )); then
      lo=$(sql "SELECT count(*) FROM session s
                WHERE NOT EXISTS (SELECT 1 FROM session_v2 v WHERE v.id = s.id);") || lo=0
    fi
    key="$OC_SCHEMA/$OC_MIGRATION/${key:-0}/$lo"
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
  t=$(sql "SELECT
             coalesce(sum(CASE cat WHEN 'ev'  THEN pgsize ELSE 0 END),0)||'|'||
             coalesce(sum(CASE cat WHEN 'pt'  THEN pgsize ELSE 0 END),0)||'|'||
             coalesce(sum(CASE cat WHEN 'msg' THEN pgsize ELSE 0 END),0)||'|'||
             coalesce(sum(CASE cat WHEN 'ses' THEN pgsize ELSE 0 END),0)
           FROM (
             SELECT pgsize, CASE
               WHEN name LIKE 'event%' THEN 'ev'
               WHEN name LIKE 'session_part%' THEN 'pt'
               WHEN name LIKE 'part%' THEN 'pt'
               WHEN name LIKE 'session_message%' THEN 'msg'
               WHEN name LIKE 'message%' THEN 'msg'
               WHEN name LIKE 'session%' OR name LIKE 'instruction%'
                 OR name LIKE 'blob%' OR name LIKE 'todo%' THEN 'ses'
               ELSE 'x'
             END AS cat
             FROM dbstat
           );") || return 1
  printf 'tables\t%s\n' "$t"

  sql "SELECT coalesce(s.directory,'')||'|'||count(*)||'|'||sum(length(e.data))
       FROM event e LEFT JOIN ($OC_SESSION_SRC) s ON s.id = e.aggregate_id
       GROUP BY s.directory;" |
  while IFS='|' read -r d n b; do
    if [[ -n "$d" ]]; then
      printf 'ev\t%s\t%s\n' "$d" "$b"
    else
      printf 'orph\t%s\t%s\n' "${n:-0}" "${b:-0}"
    fi
  done

  oc_compute_part_data
}

# per-directory data of the message/part payload. V2 moved the live data to
# session_message/session_part; the legacy message/part tables are only counted
# for V1 sessions that have no session_v2 counterpart yet (no double counting).
oc_compute_part_data() {
  local d b
  if (( OC_HAS_V2 )); then
    if (( OC_HAS_SESSION_PART )); then
      sql "SELECT s.directory||'|'||sum(length(p.data))
           FROM session_part p JOIN session_v2 s ON s.id = p.session_id
           GROUP BY s.directory;" |
      while IFS='|' read -r d b; do
        if [[ -n "$b" ]]; then printf 'pt\t%s\t%s\n' "$d" "$b"; fi
      done
    elif (( OC_HAS_SESSION_MESSAGE )); then
      sql "SELECT s.directory||'|'||sum(length(m.data))
           FROM session_message m JOIN session_v2 s ON s.id = m.session_id
           GROUP BY s.directory;" |
      while IFS='|' read -r d b; do
        if [[ -n "$b" ]]; then printf 'pt\t%s\t%s\n' "$d" "$b"; fi
      done
    fi
  fi
  if (( OC_HAS_V1 )); then
    if (( OC_HAS_V2 )); then
      sql "SELECT s.directory||'|'||sum(length(p.data))
           FROM part p JOIN session s ON s.id = p.session_id
           WHERE NOT EXISTS (SELECT 1 FROM session_v2 v WHERE v.id = s.id)
           GROUP BY s.directory;" |
      while IFS='|' read -r d b; do
        if [[ -n "$b" ]]; then printf 'pt\t%s\t%s\n' "$d" "$b"; fi
      done
    else
      sql "SELECT s.directory||'|'||sum(length(p.data))
           FROM part p JOIN session s ON s.id = p.session_id
           GROUP BY s.directory;" |
      while IFS='|' read -r d b; do
        if [[ -n "$b" ]]; then printf 'pt\t%s\t%s\n' "$d" "$b"; fi
      done
    fi
  fi
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
  (( OC_SCHEMA_INIT )) || oc_schema_init
  local out
  out=$(sqlj "SELECT id, directory, time_updated AS updated
              FROM ($OC_SESSION_SRC) WHERE parent_id IS NULL;") || out=''
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

# split BACKUP_REMOTE into host and absolute remote path. Only simple ASCII
# characters are accepted: ssh/rsync would otherwise need another layer of
# quoting for the remote shell.
backup_remote_parse() {
  local spec=${BACKUP_REMOTE:-}
  if [[ ! "$spec" =~ ^([A-Za-z0-9._@-]+):(/[A-Za-z0-9._/+@%~,=-]*)$ ]]; then
    printf '  BACKUP_REMOTE must be [user@]host:/absolute/path with simple ASCII characters (no spaces, colons or shell metacharacters): %s\n' \
      "${spec:-<empty>}" >&2
    return 1
  fi
  OC_RHOST=${BASH_REMATCH[1]}
  OC_RPATH=${BASH_REMATCH[2]}
  if [[ "$OC_RPATH" != "/" ]]; then OC_RPATH=${OC_RPATH%/}; fi
}

# run a single command string on the remote. ssh joins its arguments with
# spaces, so a separate "sh -c '…' _ path" would lose the quoting; the parser
# restricts the path to safe ASCII, therefore single quotes are enough.
backup_remote_cmd() {
  ssh -o BatchMode=yes -- "$OC_RHOST" "$1"
}

# remote backup: checkpoint the WAL, then stream the raw database with rsync –
# no local copy is created. Only used by --vacuum, where the database may be
# opened writable anyway.
run_backup_remote() {
  local file_b avail sum_local sum_remote sum_out dest t0
  file_b=$(stat -c%s "$DB")

  backup_remote_parse || return 1
  if ! command -v ssh >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    printf '  ssh and rsync are required for BACKUP_REMOTE.\n' >&2
    return 1
  fi
  printf '  to %s:%s (ssh) | size %s\n' \
    "$OC_RHOST" "$OC_RPATH" "$(fmt_b "$file_b")"

  if ! backup_remote_cmd "test -d '$OC_RPATH'"; then
    printf '  Remote backup directory missing or host unreachable: %s:%s\n' \
      "$OC_RHOST" "$OC_RPATH" >&2
    printf '  Create it (and mount its filesystem) first.\n' >&2
    return 1
  fi
  if ! backup_remote_cmd "test -w '$OC_RPATH'"; then
    printf '  Remote backup directory is not writable by the SSH user: %s:%s\n' \
      "$OC_RHOST" "$OC_RPATH" >&2
    printf '  Fix the ownership/permissions on the remote first.\n' >&2
    return 1
  fi

  if ! avail=$(backup_remote_cmd "df -B1 --output=avail '$OC_RPATH'"); then
    printf '  Cannot query free space on %s.\n' "$OC_RHOST" >&2
    return 1
  fi
  avail=$(printf '%s\n' "$avail" | tail -n1 | tr -d '[:space:]')
  if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
    printf '  Cannot parse free space on %s: %s\n' "$OC_RHOST" \
      "${avail:-empty}" >&2
    return 1
  fi
  printf '  free there %s\n' "$(fmt_b "$avail")"
  if (( avail < file_b )); then
    printf '  Not enough free space at the remote target: %s needed, %s free.\n' \
      "$(fmt_b "$file_b")" "$(fmt_b "$avail")" >&2
    return 1
  fi

  if ! backup_remote_cmd 'command -v rsync >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1'; then
    printf '  rsync and sha256sum are required on %s.\n' "$OC_RHOST" >&2
    return 1
  fi

  # rsync copies the raw file, so the WAL has to be empty for a consistent
  # snapshot; this is the same checkpoint that run_vacuum would do later
  vacuum_prepare || return 1
  if [[ -f "$DB-wal" && "$(stat -c%s "$DB-wal")" -gt 0 ]]; then
    printf '  WAL not empty after the integrity check – aborting.\n' >&2
    return 1
  fi

  sum_local=$(sha256sum -- "$DB" | awk '{print $1}')
  dest="$OC_RPATH/opencode-$(date +%Y%m%d-%H%M%S).db"
  if backup_remote_cmd "test -e '$dest'"; then
    printf '  Refusing: %s:%s already exists – run again in a second.\n' \
      "$OC_RHOST" "$dest" >&2
    return 1
  fi

  t0=$(date +%s)
  printf '  uploading (%s) …\n' "$(fmt_b "$file_b")"
  if ! rsync -e 'ssh -o BatchMode=yes' --times --whole-file --protect-args \
       --info=progress2 -- "$DB" "$OC_RHOST:$dest" >&2; then
    printf 'FAILED – removing the partial remote file.\n' >&2
    backup_remote_cmd "rm -f '$dest' '$dest-wal' '$dest-shm'" 2>/dev/null || true
    return 1
  fi

  if ! sum_out=$(backup_remote_cmd "sha256sum '$dest'"); then
    printf '  Cannot read the checksum of the remote copy.\n' >&2
    return 1
  fi
  sum_remote=$(printf '%s\n' "$sum_out" | awk '{print $1}')
  if [[ "$sum_local" != "$sum_remote" ]]; then
    printf '  checksum mismatch (local %s, remote %s) – aborting.\n' \
      "$sum_local" "${sum_remote:-none}" >&2
    return 1
  fi

  printf '  %s:%s (sha256 ok, %ss)\n' \
    "$OC_RHOST" "$dest" "$(( $(date +%s) - t0 ))"
}

# full copy of the database before anything destructive: a local verified
# ".backup" copy in $BACKUP, or – when BACKUP_REMOTE is set – a checkpointed raw
# copy streamed with rsync (no local temporary file).
run_backup() {
  # only --vacuum rewrites the file and --cleanup-legacy deletes stale V1 rows,
  # so only they need this safety net
  (( OC_BACKUP )) || return 0
  (( OC_VACUUM || OC_CLEANUP_LEGACY )) || return 0

  printf '\nBackup:\n'
  if ! db_readable; then
    printf '  sqlite3 or %s not available\n' "$DB" >&2
    return 1
  fi
  oc_guard_closed

  if [[ -n "${BACKUP_REMOTE:-}" ]]; then
    run_backup_remote
    return
  fi

  local file_b avail dest chk t0
  file_b=$(stat -c%s "$DB")

  if [[ ! -d "$BACKUP" ]]; then
    printf '  Backup directory does not exist: %s\n' "$BACKUP" >&2
    printf '  Create it (and mount its filesystem) first.\n' >&2
    return 1
  fi
  avail=$(oc_free_bytes "$BACKUP")
  printf '  to %s | size %s | free there %s\n' \
    "$BACKUP" "$(fmt_b "$file_b")" "$(fmt_b "${avail:-0}")"
  if [[ "${avail:-0}" -lt "$file_b" ]]; then
    printf '  Not enough free space at the target: %s needed, %s free.\n' \
      "$(fmt_b "$file_b")" "$(fmt_b "${avail:-0}")" >&2
    return 1
  fi

  dest="$BACKUP/opencode-$(date +%Y%m%d-%H%M%S).db"
  t0=$(date +%s)
  printf '  copying … '
  if ! sqlite3 -readonly "$DB" ".backup '$dest'"; then
    printf 'FAILED\n' >&2
    rm -f "$dest"
    return 1
  fi
  echo done

  if [[ "$(stat -c%s "$dest")" != "$file_b" ]]; then
    printf '  size mismatch: %s instead of %s – aborting.\n' \
      "$(fmt_b "$(stat -c%s "$dest")")" "$(fmt_b "$file_b")" >&2
    return 1
  fi
  # an interrupted check leaves an empty -wal/-shm next to the copy – drop them
  trap 'rm -f "$dest-wal" "$dest-shm"; exit 130' INT TERM
  printf '  integrity check of the copy (reads the whole backup again) … '
  chk=$(sqlite3 -readonly "$dest" 'PRAGMA integrity_check;') || chk=''
  trap - INT TERM
  if [[ "$chk" != "ok" ]]; then
    printf 'FAILED (%s) – aborting.\n' "$chk" >&2
    return 1
  fi
  echo ok
  # reading a WAL-mode copy creates an empty -wal/-shm next to it – drop them
  if [[ ! -f "$dest-wal" || "$(stat -c%s "$dest-wal")" -eq 0 ]]; then
    rm -f "$dest-wal" "$dest-shm"
  fi
  printf '  %s (integrity ok, %ss)\n' "$dest" "$(( $(date +%s) - t0 ))"
}

run_apply() {
  local sessions=$1
  (( OC_SCHEMA_INIT )) || oc_schema_init

  if (( APPLY == 0 )); then
    if (( OC_VACUUM == 0 && OC_CLEANUP_LEGACY == 0 )); then
      printf '\nDry run. To delete: %s --apply\n' "$0"
      exit 0
    fi
    # --cleanup-legacy already ran in the entry script; --vacuum without --apply
    # compacts only, nothing is deleted here
    if (( OC_VACUUM )); then
      run_vacuum
    fi
    exit 0
  fi

  oc_guard_closed

  if [[ "$OC_SCHEMA" == "mixed" ]]; then
    printf 'The V1 -> V2 migration is still running. Let opencode v2 finish it first\n' >&2
    printf '(start it once and wait until it is idle), then run this again.\n' >&2
    exit 1
  fi

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
    done < <(sql "SELECT id||'|'||directory FROM ($OC_SESSION_SRC) WHERE parent_id IS NOT NULL;")
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
      oc_export_session "$id" > "$out/$id.json"
      if [[ ! -s "$out/$id.json" ]]; then
        echo "Empty export: $id" >&2
        exit 1
      fi
      "${OC_BIN:-opencode}" session delete "$id"
      # v2 deleted only session_v2/events; drop the stale V1 copy of the subtree
      if (( OC_LEGACY )) && [[ "$OC_SCHEMA" == "v2" ]]; then
        oc_legacy_delete_subtree "$id"
      fi
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

# --- V1 leftovers in a migrated V2 store --------------------------------
# opencode v2 copies the V1 sessions into session_v2/session_message but keeps
# the legacy "session"/"message"/"part" rows. Deleting through the v2 CLI only
# touches the v2 tables, so these helpers remove the stale V1 rows afterwards.

# legacy sessions without a session_v2 counterpart (already deleted in v2)
oc_legacy_orphan_ids() {
  (( OC_LEGACY )) || return 0
  [[ "$OC_SCHEMA" == "v2" ]] || return 0
  sql "SELECT id FROM session s WHERE NOT EXISTS (SELECT 1 FROM session_v2 v WHERE v.id = s.id);"
}

# delete one session subtree from the legacy V1 tables. targets_sub is deleted
# after the v2 root, so the legacy children are reached through parent_id.
oc_legacy_delete_subtree() {
  local id=$1
  (( OC_LEGACY )) || return 0
  [[ "$OC_SCHEMA" == "v2" ]] || return 0
  if [[ ! "$id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '  Refusing to delete an unsafe legacy session id: %s\n' "$id" >&2
    return 1
  fi
  sqlw "PRAGMA foreign_keys=ON;
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        WITH RECURSIVE tree(id) AS (
          SELECT id FROM session WHERE id='$id'
          UNION
          SELECT s.id FROM session s JOIN tree t ON s.parent_id = t.id
        )
        DELETE FROM session WHERE id IN (SELECT id FROM tree);
        COMMIT;" >/dev/null
}

# --cleanup-legacy: backup already happened, now drop every stale V1 row
run_cleanup_legacy() {
  (( OC_CLEANUP_LEGACY )) || return 0
  (( OC_SCHEMA_INIT )) || oc_schema_init

  printf '\nLegacy cleanup:\n'
  if ! db_readable; then
    printf '  sqlite3 or %s not available\n' "$DB" >&2
    return 1
  fi
  case "$OC_SCHEMA" in
    v1)
      printf '  V1 schema, no leftover rows from a v2 migration.\n'
      return 0 ;;
    mixed)
      printf '  The V1 -> V2 migration is still running, aborting.\n' >&2
      return 1 ;;
    none)
      printf '  no session table detected, nothing to clean.\n'
      return 0 ;;
  esac
  if (( ! OC_LEGACY )); then
    printf '  no legacy V1 tables detected, nothing to clean.\n'
    return 0
  fi

  oc_guard_closed

  local ids n
  ids=$(oc_legacy_orphan_ids) || return 1
  n=$(printf '%s\n' "$ids" | awk 'NF{n++} END{print n+0}')
  if (( n == 0 )); then
    printf '  no stale V1 rows to remove.\n'
    return 0
  fi

  printf '  removing %s stale V1 sessions (V1 rows without session_v2) ... ' "$n"
  if ! sqlw "PRAGMA foreign_keys=ON;
             PRAGMA busy_timeout=5000;
             BEGIN IMMEDIATE;
             DELETE FROM session WHERE id NOT IN (SELECT id FROM session_v2);
             COMMIT;" >/dev/null; then
    printf 'FAILED\n' >&2
    return 1
  fi
  printf 'done\n'
}

# checkpoint + integrity check – shared by both vacuum routes
vacuum_prepare() {
  local busy chk
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
}

# compact the database – the only place where it is opened writable.
# VACUUM INTO instead of a plain VACUUM: a plain VACUUM needs up to twice the
# file size as free space, VACUUM INTO only needs the compacted copy. The check
# below therefore reserves the expected compacted size (live pages + margin).

# expected size of the compacted copy: live pages plus a safety margin
vacuum_need() {
  local prg pages psize freelist
  prg=$(sql "SELECT page_count||'|'||page_size||'|'||freelist_count
             FROM pragma_page_count, pragma_page_size, pragma_freelist_count;") || prg=''
  [[ -n "$prg" ]] || return 1
  IFS='|' read -r pages psize freelist <<< "$prg"
  OC_VAC_LIVE=$(( (${pages:-0} - ${freelist:-0}) * ${psize:-0} ))
  OC_VAC_MARGIN=$(( OC_VAC_LIVE / 10 ))
  (( OC_VAC_MARGIN < 268435456 )) && OC_VAC_MARGIN=268435456
  OC_VAC_NEED=$(( OC_VAC_LIVE + OC_VAC_MARGIN ))
}

run_vacuum() {
  printf '\nVacuum:\n'
  if ! db_readable; then
    printf '  sqlite3 or %s not available\n' "$DB" >&2
    return 1
  fi

  oc_guard_closed

  local file_b avail tmp chk after need a
  file_b=$(stat -c%s "$DB")
  avail=$(oc_free_bytes "$(dirname "$DB")")
  tmp="$DB.vac"

  vacuum_need || {
    printf '  Cannot read the database page counts – aborting.\n' >&2
    return 1
  }
  need=$OC_VAC_NEED

  printf '  before %s | free on disk %s | expected compacted ~%s | reserve %s\n' \
    "$(fmt_b "$file_b")" "$(fmt_b "${avail:-0}")" \
    "$(fmt_b "$OC_VAC_LIVE")" "$(fmt_b "$need")"

  if [[ "${avail:-0}" -lt "$need" ]]; then
    printf '  The expected compacted copy (~%s + margin = %s) does not fit:\n' \
      "$(fmt_b "$OC_VAC_LIVE")" "$(fmt_b "$need")" >&2
    printf '  only %s is free on the database filesystem.\n' \
      "$(fmt_b "${avail:-0}")" >&2
    # only --vacuum ever gets here, and only a terminal is asked – scripted
    # runs must free the space themselves (OC_PROMPT=1 forces the question)
    if [[ -t 0 || "${OC_PROMPT:-}" == "1" ]] && [[ -d "$BACKUP" ]]; then
      printf '  Compact via %s instead: the compacted copy travels over the\n' \
        "$BACKUP" >&2
      printf '  network and is copied over the database, which frees the old file\n' >&2
      printf '  first. It fits locally as long as the compacted copy is at most\n' >&2
      printf '  %s (old file + %s free).\n' \
        "$(fmt_b "$(( file_b + avail ))")" "$(fmt_b "$avail")" >&2
      printf '  Do it via the backup target? [y/N] ' >&2
      a=''
      read -r a || a=''
      case "$a" in
        [yY]*) run_vacuum_remote "$file_b" "$avail"; return $? ;;
        *) printf '  Aborted – nothing was changed.\n' >&2; return 1 ;;
      esac
    fi
    if [[ -d "${BACKUP:-}" ]]; then
      printf '  Free space first (or attach a terminal to compact via %s).\n' "$BACKUP" >&2
    else
      printf '  Free space first.\n' >&2
    fi
    return 1
  fi
  if [[ -e "$tmp" ]]; then
    printf '  Refusing: %s already exists – remove it first.\n' "$tmp" >&2
    return 1
  fi

  vacuum_prepare || return 1

  printf '  VACUUM INTO %s … ' "$(basename "$tmp")"
  if ! sqlw "VACUUM INTO '$tmp';" >/dev/null; then
    printf 'FAILED\n' >&2
    rm -f "$tmp"
    printf '  Original database untouched. Free space or use the backup target route.\n' >&2
    return 1
  fi
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

# fallback when the database filesystem is too small: write the compacted copy
# to the backup target and copy it back over the database. "cp" truncates its
# target first, so the old file is freed before the compacted copy is written –
# locally only what exceeds file_b + avail is missing. The verified copy on the
# backup target stays until the local one passed its check.
run_vacuum_remote() {
  local file_b=$1 avail=$2 dest navail chk after csize extra
  dest="$BACKUP/vacuum-$(date +%Y%m%d-%H%M%S).db"

  navail=$(oc_free_bytes "$BACKUP")
  if [[ "${navail:-0}" -lt "$file_b" ]]; then
    printf '  Not enough free space at %s: %s needed, %s free.\n' \
      "$BACKUP" "$(fmt_b "$file_b")" "$(fmt_b "${navail:-0}")" >&2
    return 1
  fi
  if [[ -e "$dest" ]]; then
    printf '  Refusing: %s already exists – remove it first.\n' "$dest" >&2
    return 1
  fi

  vacuum_prepare || return 1

  printf '  VACUUM INTO %s (over the network, this takes a while) … ' "$dest"
  sqlw "VACUUM INTO '$dest';" >/dev/null
  echo done

  printf '  integrity check of the copy … '
  chk=$(sqlite3 -readonly "$dest" 'PRAGMA integrity_check;') || chk=''
  if [[ "$chk" != "ok" ]]; then
    printf 'FAILED (%s) – database untouched.\n' "$chk" >&2
    return 1
  fi
  echo ok

  # cp truncates the database first: the space it occupies becomes free, so only
  # a compacted copy bigger than file_b + avail would not fit
  csize=$(stat -c%s "$dest")
  extra=$(( csize > file_b ? csize - file_b : 0 ))
  if (( extra > avail )); then
    printf '  Not enough free space locally: the compacted copy is %s, the old\n' \
      "$(fmt_b "$csize")" >&2
    printf '  file frees %s and %s is free – %s short.\n' \
      "$(fmt_b "$file_b")" "$(fmt_b "$avail")" \
      "$(fmt_b "$(( extra - avail ))")" >&2
    printf '  Database untouched. The verified copy stays at:\n  %s\n' "$dest" >&2
    printf '  free the space, then: cp %s %s\n' "$dest" "$DB" >&2
    return 1
  fi

  printf '  copying it back over %s … ' "$(basename "$DB")"
  if ! cp -f "$dest" "$DB"; then
    printf 'FAILED – restore with: cp %s %s\n' "$dest" "$DB" >&2
    return 1
  fi
  echo done

  # the emptied WAL/SHM belong to the old file, never reuse them
  rm -f "$DB-wal" "$DB-shm"

  printf '  integrity check of the database … '
  chk=$(sqlw 'PRAGMA integrity_check;') || chk=''
  if [[ "$chk" != "ok" ]]; then
    printf 'FAILED (%s)\n' "$chk" >&2
    printf '  restore it with: cp %s %s\n' "$dest" "$DB" >&2
    return 1
  fi
  echo ok
  sqlw 'PRAGMA journal_mode=WAL;' >/dev/null || true

  after=$(stat -c%s "$DB")
  printf '  after  %s (freed %s)\n' \
    "$(fmt_b "$after")" "$(fmt_b "$(( file_b - after ))")"
  rm -f "$dest"
  printf '  (temporary copy at the backup target removed)\n'
}
