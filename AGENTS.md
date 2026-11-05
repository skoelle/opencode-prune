# AGENTS.md – opencode-prune

Script collection that tidies up opencode sessions: **the analysis (dry run) is the
default**, deleting only happens with `--apply`. Everything in this repository –
source, comments, messages, docs – is written in **English**, and no personal paths,
names, IDs or credentials may be committed (`.env` is gitignored for that reason).

## Structure

| File | Contents |
|---|---|
| `oc-lib.sh` | shared logic (sourced by both scripts): `oc_init`, `oc_args`, `oc_schema_init` (V1/V2 detection + `OC_SESSION_SRC`), `oc_cli_version`, `db_report`, `oc_augment_missing`, `oc_filter_only`, `db_sizes`, `print_table`, `run_backup` (+ `run_backup_remote`, `backup_remote_parse`), `oc_export_session`, `run_apply`, `run_cleanup_legacy` (+ `oc_legacy_orphan_ids`, `oc_legacy_delete_subtree`), `run_vacuum` (+ `vacuum_prepare`, `vacuum_need`, `run_vacuum_remote`, helpers `oc_guard_closed`, `oc_free_bytes`) |
| `oc-prune.sh` | scan with `opencode session list` per directory, progress on stderr |
| `oc-prune-db.sh` | scan with one `SELECT` (fast, complete) |
| `.env` | local configuration; precedence: environment variable → `.env` → default |
| `.env.example`, `.gitignore` | template and protection against publishing personal paths |
| `README.md` | user documentation |

Both scripts are thin: configuration, scan, then calls into `oc-lib.sh`. Put new shared
logic into the lib instead of duplicating it.

## Rules

- **Read the opencode database with `sqlite3 -readonly`.** The writable paths are
  `--vacuum` (`run_vacuum` uses `PRAGMA wal_checkpoint(TRUNCATE)`,
  `PRAGMA integrity_check`, `VACUUM INTO` and the swap including removal of the stale
  `-wal`/`-shm`; `run_backup` uses the checkpoint only when `BACKUP_REMOTE` is set,
  because the raw `rsync` snapshot needs an empty WAL) and the V1 cleanup
  (`run_cleanup_legacy` / the targeted `oc_legacy_delete_subtree` in `run_apply` delete
  only stale `session` rows after opencode v2 migrated them; `PRAGMA foreign_keys=ON`,
  one transaction, never v2 tables). Without `BACKUP_REMOTE`, `run_backup` stays
  read-only (`sqlite3 -readonly "$DB" ".backup ..."`). Besides our size cache under
  `~/.cache/oc-prune/`, only `$BACKUP` (exports/local backup) and `$BACKUP_REMOTE`
  (full database backup) are written to.
- **`run_vacuum` has two routes**, both writing only through `sqlw` + `mv`/`cp`: the
  normal one (`VACUUM INTO '$DB.vac'` next to the database, needs the expected
  compacted size – live pages + 10 % margin, at least 256 MiB – free) and
  `run_vacuum_remote` (into `$BACKUP`, then `cp` over the database – used only when
  a terminal answered `y` to the question about the missing space). The question is
  asked **only** with `--vacuum` and only when stdin is a terminal; `OC_PROMPT=1`
  forces it for tests. The remote route must **not** require the uncompressed file
  size locally: `cp` truncates the database first, so its local check uses the actual
  compacted size after `VACUUM INTO` (`compacted ≤ file + free`) and aborts with the
  verified `$BACKUP` copy left in place if even that does not fit.
- **`--vacuum` and `--cleanup-legacy` are backup-first**: `run_backup` runs before
  `run_apply`/`run_cleanup_legacy` in both entry scripts, so a copy exists before
  anything is deleted or rewritten. Without `BACKUP_REMOTE` it needs the directory
  `$BACKUP` to already exist (a not mounted path would silently write to `/`) and as
  much free space there as the database is big; the copy is verified with
  `PRAGMA integrity_check`, which reads it **again** – on a network target that takes
  about as long as the copy, so keep the progress line announced before it. With
  `BACKUP_REMOTE` the raw database is checkpointed, streamed with `rsync` (no local
  copy) and verified with `sha256sum` on both sides; the remote directory must already
  exist, be writable by the SSH user and have the database size free. `run_vacuum` in
  turn **aborts unless the database filesystem has the expected compacted size
  (live pages + margin: 10 %, min. 256 MiB) free** – keep those rules when touching
  either function, and document them in the README command reference.
- **The V1 leftovers of a v2 migration are deleted separately from the v2 tables.**
  `--apply` only deletes the legacy copy of a session it already deleted through the
  v2 CLI; `--cleanup-legacy` deletes all `session` rows without a `session_v2`
  counterpart. Both require `OC_SCHEMA=v2` and a `completed` `kv` state
  (`migration.v1-v2`); a running migration (`mixed`) aborts. Legacy data was already
  dropped in v2 and cascades to `message`/`part` via `PRAGMA foreign_keys=ON`, so keep
  that transaction atomic and never touch v2 tables.
- **`BACKUP_REMOTE` is only for the full backup before `--vacuum`/`--cleanup-legacy`.**
  Exports still go to `$BACKUP`. The format is `[user@]host:/absolute/path` (simple
  ASCII, no spaces, colons or shell metacharacters in the path). SSH runs with
  `BatchMode=yes`, so keys must be set up. The remote needs `rsync` and `sha256sum`;
  `sqlite3` is not required because the source is integrity-checked locally and the
  transfer is checksum-verified.
- **Never run `--apply`, `--vacuum` or `--cleanup-legacy` without explicit approval.**
  Verify with a dry run and by generating the target lists (see below). The same holds
  for these actions against the real database – they rewrite or delete. Test the
  mechanics on a copy in `/tmp`.
- Global rules from `~/.config/opencode/AGENTS.md` apply as well (among others: no
  co-authors in commits).

## Conventions

- Every script starts with `set -euo pipefail` and sources the lib via
  `$(dirname "${BASH_SOURCE[0]}")`.
- **stdout stays free of anything but JSON**: `SESSIONS=$(…)` collects stdout. All
  progress and info messages go through `printf … >&2`.
- Set defaults only inside `oc_init`, **after** `load_env` – otherwise the default
  overwrites the value from `.env` and the file has no effect.
- Flags (`--apply`, `--vacuum`, `--cleanup-legacy`, `--no-backup`, `--help`) are parsed
  once in `oc_args`; the entry scripts only call `oc_init` + `oc_args "$@"`. Keep both
  scripts identical there, including the `run_backup` → `run_cleanup_legacy` → `run_apply`
  order.
- Bind a variable before a jq filter uses it (`(.directory) as $d | if ($miss | index($d)) …`).
  `index(.[0].directory)` inside `$miss |` refers to the wrong `.` and jq reports a
  parse/type error.
- Use `printf` for output; adjust the column widths in `print_table` and in the `awk`
  formatter whenever a column is added.

## Pitfalls already paid for

- `length(CAST(data AS BLOB))` over the 4 GiB `event` table gets killed by the OOM
  killer. Use `length(data)` (characters, slightly underestimates multi-byte characters)
  plus `PRAGMA cache_size=8000` (otherwise ~3 GiB RSS, with it ~1,3 GiB).
- `GROUP BY 1` with aggregates in the same select list is forbidden in SQLite →
  `GROUP BY <column>`.
- `pgrep -f 'opencode'` also matches `vim opencode.json` and our own command line
  (`.../opencode-prune/...`) → `pgrep -x opencode` (plus `-x opencode2` and the
  `OC_BIN` basename, because a v2 preview may run under another name).
- The `session` table has **no CASCADE on `parent_id`**: subagent sessions of missing
  directories must be deleted before the top-level sessions, otherwise orphans remain.
- `opencode session list` only returns the project of the current working directory;
  sessions of missing directories and sessions of a second project in the same
  directory are missing. `oc_augment_missing` adds sessions of missing directories back.
- Cache key over `count(*)`/`max(time_created)`, **not** over `max(time_updated)` –
  that changes all the time while opencode runs and the cache would never hit. Include
  `OC_SCHEMA`/`OC_MIGRATION` and the V1-orphan count so a v1 → v2 upgrade invalidates it.
- A v2 store keeps the old `session`/`message`/`part` tables after the in-place
  migration. `session_v2` (not `event`/`session_message`) is the v2 marker, and the
  migration state lives in `kv` under `migration.v1-v2`. After `completed`, read only
  `session_v2` – a union would resurrect sessions deleted in v2 through their V1 copies.
- v1 exports with `opencode export`, v2 only with `opencode session export`;
  `oc_export_session` chooses based on `OC_SCHEMA`.
- `oc_cli_version` uses the last non-empty line of `--version` (some builds print a
  banner first) and falls back to `unknown`; only parse the major when it is numeric.
  The version line and the mismatch hint (`schema v2` + CLI v1, `schema v1` + CLI v2)
  are informational – they must not change any behaviour.
- Deleting through the v2 CLI does not touch the V1 tables: `--apply` must delete the
  legacy subtree itself, otherwise the rows stay and `--vacuum` cannot reclaim them.
- Bucket `dbstat` by explicit names, not `LIKE 'session%'`: in v2 `session_message%`
  and `session_part%` would otherwise land in the `session` bucket. Check `session_part`
  and `session_message` before `session`.

## Keep the deletion rule in sync in four places

Whoever changes the rules (currently: “directory missing → keep nothing”) has to adjust:

1. `print_table` – the `DELETE` column (jq filter over `--argjson miss "$OC_MISSING"`)
2. `print_table` – the `Total` line (second jq call, same condition)
3. `run_apply` – the target list `$TMP/targets` (otherwise the table promises something
   different from what is deleted)
4. `run_apply` – the legacy subtree delete (`oc_legacy_delete_subtree` in a migrated v2
   store) must cover exactly the sessions that were deleted through the CLI

Also keep `db_report`, which fills `OC_MISSING`/`OC_MISSING_DIRS`, `oc_filter_only`
(`ONLY`) and the active session source `OC_SESSION_SRC` (built by `oc_schema_init`) in
mind.

## Verification

```bash
for f in oc-lib.sh oc-prune.sh oc-prune-db.sh; do bash -n "$f"; done
./oc-prune-db.sh --help                    # usage, exit 0
./oc-prune-db.sh --quatsch                 # unknown option, exit 1
SIZES=0 ./oc-prune-db.sh                   # dry run without size computation (~0 s)
SIZES=0 ./oc-prune-db.sh --vacuum          # must stop: "opencode is still running"
ONLY=/path/to/project ./oc-prune-db.sh     # dry run limited to one directory
```

`BACKUP_REMOTE` parsing without any network access:

```bash
bash -c 'source ./oc-lib.sh; BACKUP_REMOTE=user@host:/path/to/backup
  backup_remote_parse; echo "$OC_RHOST|$OC_RPATH"'
# expect: user@host|/path/to/backup
bash -c 'source ./oc-lib.sh; BACKUP_REMOTE="user@host:relative"; backup_remote_parse'
# expect: error "must be [user@]host:/absolute/path", exit 1
bash -c 'source ./oc-lib.sh; BACKUP_REMOTE="user@host:/path with space"; backup_remote_parse'
# expect: same error, exit 1
```

> ⚠️ Always run the dry-run/destructive tests with `ENV_FILE=/dev/null` and an explicit
> `DB=/tmp/...`: with the real `.env` a `BACKUP_REMOTE` test would upload to the real
> backup target. Never point the fixtures at the real `$DB`.

Schema + legacy cleanup on synthetic copies (a migrated v2 store is a copy of a v1
store plus `session_v2`/`session_message`/`session_part` and a `kv` row
`migration.v1-v2 = {"phase":"completed"}`; opencode is faked with a small script in
`PATH` that only deletes `session_v2` and a `pgrep` stub that returns 1):

```bash
ENV_FILE=/dev/null DB=/tmp/oc-v2-test/v2mig.db SIZES=0 BACKUP=/tmp/oc-v2-test/bk \
  ./oc-prune-db.sh                       # "schema v2", "V1 rows N", union off
# expect below the schema line: "opencode <version> (CLI) | sessions up to <version>",
# and with a v1 CLI on the v2 fixture a "WARNING: database is v2 but the CLI is v1"
ENV_FILE=/dev/null DB=/tmp/oc-v2-test/v2mixed.db SIZES=0 ./oc-prune-db.sh
# expect: "schema v2, V1 migration still running (sessions)", legacy rows in the table
ENV_FILE=/dev/null DB=/tmp/oc-v2-test/v2mig.db SIZES=0 ./oc-prune-db.sh --apply
# expect: abort with "V1 -> V2 migration is still running" for the mixed fixture
# with the fake opencode + pgrep stub: --apply deletes the V1 subtree too; --cleanup-legacy
# removes only the `session` rows without a `session_v2` counterpart and cascades to
# message/part; `PRAGMA integrity_check` stays ok
```

The actual remote flow is tested against the real target on a **copy** of the database
in `/tmp` (never the real `$DB`): set `BACKUP_REMOTE=user@host:/tmp/oc-vac-test/remote`,
`BACKUP` to a local directory, and run `run_backup` with `pgrep(){ return 1; }` and
`OC_BACKUP=1 OC_VACUUM=1`; expect a timestamped `.db` on the remote, a matching
`sha256sum`, and no local copy.

Backup + vacuum mechanics on isolated copies (opencode faked as closed – never point
this at the real `$DB`):

```bash
mkdir -p /tmp/oc-vac-test/bk
sqlite3 /tmp/oc-vac-test/test.db "PRAGMA journal_mode=WAL;
  CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
  INSERT INTO t(v) SELECT randomblob(20000) FROM generate_series(1,6000);
  DELETE FROM t WHERE id % 2 = 0;"
bash -c 'source ./oc-lib.sh; pgrep(){ return 1; }; OC_BACKUP=1; OC_VACUUM=1
  BACKUP=/tmp/oc-vac-test/bk; DB=/tmp/oc-vac-test/test.db; TMP=$(mktemp -d)
  run_backup; run_vacuum'
# expect: /tmp/oc-vac-test/bk/opencode-<ts>.db (integrity ok), half the size,
#         integrity_check ok, journal_mode wal, no leftover .vac
bash -c 'source ./oc-lib.sh; pgrep(){ return 1; }; OC_BACKUP=0; OC_VACUUM=1
  BACKUP=/tmp/oc-vac-test/bk; DB=/tmp/oc-vac-test/test.db; TMP=$(mktemp -d)
  run_backup; run_vacuum'
# expect: no new file in bk/, same vacuum result
```

The fallback question (stub `oc_free_bytes` so the local disk looks too small, but
still large enough for the compacted copy; `OC_PROMPT=1` fakes the terminal):

```bash
OC_PROMPT=1 bash -c 'source ./oc-lib.sh; pgrep(){ return 1; }
  oc_free_bytes(){ if [[ "$1" == "$(dirname "$DB")" ]]; then echo 130000000;
    else df -B1 --output=avail "$1" | tail -n1 | tr -d " "; fi; }
  BACKUP=/tmp/oc-vac-test/bk; DB=/tmp/oc-vac-test/test.db; TMP=$(mktemp -d)
  run_vacuum' <<< y
# expect: "Do it via the backup target? [y/N]", VACUUM INTO $BACKUP/vacuum-<ts>.db,
#         copy back, integrity ok, temporary copy removed
# <<< n  -> "Aborted – nothing was changed", database unchanged
# without OC_PROMPT and stdin < /dev/null -> "Free space first", exit 1

# local check after VACUUM INTO: pass file_b too small so extra > avail
bash -c 'source ./oc-lib.sh; pgrep(){ return 1; }
  BACKUP=/tmp/oc-vac-test/bk; DB=/tmp/oc-vac-test/test.db
  run_vacuum_remote 1000 0'
# expect: "Not enough free space locally … Database untouched", exit 1,
#         database unchanged, verified vacuum-<ts>.db left in $BACKUP
```

To check target lists without deleting (no `opencode` call, no DB write): run the jq line
from `run_apply` against `SESSIONS` and print `$TMP/targets` plus `$TMP/targets_sub`.
The expected line count equals the `DELETE` sum of the table (plus subagent lines of
missing directories).

Afterwards review the files; update `README.md` whenever the output, the variables or
the rules change.
