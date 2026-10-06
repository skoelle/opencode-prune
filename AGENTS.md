# AGENTS.md – opencode-prune

Script collection that tidies up opencode sessions: **the analysis (dry run) is the
default**, deleting only happens with `--apply`. Everything in this repository –
source, comments, messages, docs – is written in **English**, and no personal paths,
names, IDs or credentials may be committed (`.env` is gitignored for that reason).

## Structure

| File | Contents |
|---|---|
| `oc-lib.sh` | shared logic (sourced by both scripts): `oc_init`, `db_report`, `oc_augment_missing`, `oc_filter_only`, `db_sizes`, `print_table`, `run_apply` |
| `oc-prune.sh` | scan with `opencode session list` per directory, progress on stderr |
| `oc-prune-db.sh` | scan with one `SELECT` (fast, complete) |
| `.env` | local configuration; precedence: environment variable → `.env` → default |
| `.env.example`, `.gitignore` | template and protection against publishing personal paths |
| `README.md` | user documentation |

Both scripts are thin: configuration, scan, then calls into `oc-lib.sh`. Put new shared
logic into the lib instead of duplicating it.

## Rules

- **Only read the opencode database with `sqlite3 -readonly`.** The only thing ever
  written is our own size cache under `~/.cache/oc-prune/` (plus `$BACKUP` during an
  export).
- **Never run `--apply` without explicit approval.** Verify with a dry run and by
  generating the target lists (see below).
- Global rules from `~/.config/opencode/AGENTS.md` apply as well (among others: no
  co-authors in commits).

## Conventions

- Every script starts with `set -euo pipefail` and sources the lib via
  `$(dirname "${BASH_SOURCE[0]}")`.
- **stdout stays free of anything but JSON**: `SESSIONS=$(…)` collects stdout. All
  progress and info messages go through `printf … >&2`.
- Set defaults only inside `oc_init`, **after** `load_env` – otherwise the default
  overwrites the value from `.env` and the file has no effect.
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
  (`…/opencode-prune/…`) → `pgrep -x opencode`.
- The `session` table has **no CASCADE on `parent_id`**: subagent sessions of missing
  directories must be deleted before the top-level sessions, otherwise orphans remain.
- `opencode session list` only returns the project of the current working directory;
  sessions of missing directories and sessions of a second project in the same
  directory are missing. `oc_augment_missing` adds sessions of missing directories back.
- Cache key over `count(*)`/`max(time_created)`, **not** over `max(time_updated)` –
  that changes all the time while opencode runs and the cache would never hit.

## Keep the deletion rule in sync in three places

Whoever changes the rules (currently: “directory missing → keep nothing”) has to adjust:

1. `print_table` – the `DELETE` column (jq filter over `--argjson miss "$OC_MISSING"`)
2. `print_table` – the `Total` line (second jq call, same condition)
3. `run_apply` – the target list `$TMP/targets` (otherwise the table promises something
   different from what is deleted)

Also keep `db_report`, which fills `OC_MISSING`/`OC_MISSING_DIRS`, and
`oc_filter_only` (`ONLY`) in mind.

## Verification

```bash
for f in oc-lib.sh oc-prune.sh oc-prune-db.sh; do bash -n "$f"; done
SIZES=0 ./oc-prune-db.sh                  # dry run without size computation (~0 s)
ONLY=/path/to/project ./oc-prune-db.sh     # dry run limited to one directory
```

To check target lists without deleting (no `opencode` call, no DB write): run the jq line
from `run_apply` against `SESSIONS` and print `$TMP/targets` plus `$TMP/targets_sub`.
The expected line count equals the `DELETE` sum of the table (plus subagent lines of
missing directories).

Afterwards review the files; update `README.md` whenever the output, the variables or
the rules change.
