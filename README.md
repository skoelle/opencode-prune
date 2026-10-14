# 🧹 opencode-prune

> Clean up sessions in the opencode database – **the analysis (dry run) is the default**,
> deleting only happens with `--apply`.

| | |
|---|---|
| 🏃 Dry run first | `./oc-prune-db.sh` – nothing is modified |
| 💥 Delete | `./oc-prune-db.sh --apply` – export, then delete |
| 🗜️ Compact | `./oc-prune-db.sh --vacuum` – verified backup of the database, then compact it |
| 🔒 Database | read-only (`sqlite3 -readonly`), the only exception is `--vacuum` |
| 📦 Export | every session is exported to `BACKUP` **before** it is deleted |

---

## 📑 Contents

- [✨ What you get](#-what-you-get)
- [🗑️ Deletion rules](#-deletion-rules)
- [🧭 Command reference](#-command-reference)
- [📁 Files](#-files)
- [⚙️ Configuration](#-configuration)
- [🚀 Deleting sessions](#-deleting-sessions)
- [🗜️ Reclaiming disk space](#-reclaiming-disk-space)
- [🗄️ Database access](#-database-access)
- [🧰 Requirements](#-requirements)
- [⚠️ Gotchas](#-gotchas)

---

## ✨ What you get

```
Database (read-only): $HOME/.local/share/opencode/opencode.db
  file 4.59 GiB | WAL 59.1 MiB | freelist 0 B (0.0 %)
  sessions 381 (+ 199 subagents)
  Missing directories:
    /home/user/projects/legacy-tool                4 sessions (+2 subagents)
    /home/user/projects/gone-again                 3 sessions
  event 4.04 GiB | part 297.7 MiB | message 240.1 MiB | session 316.0 KiB
  orphan events 0 (0 B) | data per directory: cached (snapshot 580/…)

Rule: older than 30 days, keep at least 3 per directory
Rule: missing directory, keep nothing
Cutoff: 2026-09-06

DIRECTORY                                   COUNT      NEWEST      OLDEST   DELETE        MB    NOTE
/home/user/projects/legacy-tool                4  2026-08-10  2026-08-10        4       7.2 missing
/home/user/projects/demo-app                  25  2026-09-28  2026-09-20        0    1773.8

Total: 381 sessions in 34 directories, 267 deletable

Dry run. To delete: ./oc-prune-db.sh --apply
```

### 📊 Columns

| Column | Emoji | Meaning |
|---|---|---|
| `COUNT` | 🔢 | top-level sessions in the directory (subagent sessions not counted) |
| `NEWEST` / `OLDEST` | 📅 | date of the youngest / oldest session |
| `DELETE` | 🗑️ | how many sessions `--apply` would remove |
| `MB` | 💾 | event + part data of that directory in the database (`-` while sizes are not computed yet) |
| `NOTE` | 🏷️ | `missing` = directory no longer exists, `outside` = outside of `ROOT` |

### 📈 Besides the table

| | |
|---|---|
| 📂 | **Missing directories** with their session and subagent counts – your main cleanup targets |
| 🏭 | **Table sizes** (`event`, `part`, `message`, `session`) and the **freelist** – space inside the file that a `--vacuum` could give back |
| 🕳️ | **Orphan events** without a session (should be `0`) |
| ⏱️ | **Scan progress** per directory (`oc-prune.sh`) or a single `0 s` query (`oc-prune-db.sh`) |

---

## 🗑️ Deletion rules

1. 🕰️ **Default**: sessions older than `DAYS` (default **30**) – but the `MIN` (default **3**)
   youngest sessions of each directory always stay.
2. 🚫 **Missing directory**: if the directory is gone, **nothing is kept** – not even
   recent sessions.
3. 🧬 On top of that the **subagent sessions** of those directories are removed, because
   the `session` table has no `CASCADE` on `parent_id`.

---

## 🧭 Command reference

Every command starts with the same report and the same table – only the options after
that differ. Steps in **bold** are the ones that change something.

### `./oc-prune-db.sh` (no option) – dry run

1. read environment and `.env`
2. open the database **read-only**: file size, WAL, freelist, session count,
   missing directories, table sizes, orphan events, data per directory
3. **read-only scan** of all top-level sessions (one `SELECT`; `oc-prune.sh` runs
   `opencode session list` per directory instead)
4. the table with the `DELETE` counts and the total
5. `Dry run. To delete: …` – nothing is exported, nothing is deleted, the database is
   never opened writable

### `--apply` – export and delete

1. 🛑 `pgrep -x opencode` – abort with code 1 while an instance runs
2. `Export to: $BACKUP`, create the directory
3. build the target list (rule 2 and rule 1), subagents of missing directories first
4. **per session**: `opencode export <id> > $BACKUP/<directory>/<id>.json` → an empty
   export **aborts** the run → `opencode session delete <id>`
5. `Freelist after delete: …` plus the hint to compact with `--vacuum`

### `--vacuum` – backup and compact (with or without `--apply`)

1. 🛑 `pgrep -x opencode` – abort with code 1 while an instance runs
2. **backup** (skipped with `--no-backup`):
   `$BACKUP` must already exist and have at least the size of the database free →
   `sqlite3 -readonly "$DB" ".backup '$BACKUP/opencode-<timestamp>.db'"` →
   size compared with the original → `PRAGMA integrity_check` on the copy
3. **space check**: the filesystem of the database must have at least **2×** the file
   size free (a plain `VACUUM` can need that much), otherwise abort
4. **if that check fails and a terminal is attached**: the question
   `Do it via the backup target? [y/N]` – on `y` the compacted copy is written to
   `$BACKUP` and copied back over the database ([details](#when-the-disk-is-too-small)),
   on `n` the run stops without changing anything
5. `PRAGMA wal_checkpoint(TRUNCATE)` – abort if the WAL stays non-empty
6. `PRAGMA integrity_check` on the database
7. **`VACUUM INTO '$DB.vac'`** – a copy, the original is untouched if anything fails
8. `PRAGMA integrity_check` on the copy, then the **swap**: `mv` over `$DB`, the old
   `-wal`/`-shm` are removed, `journal_mode=wal` is restored
9. `before`, `after` and what was freed

### The combinations

| Command | Steps that run |
|---|---|
| *(none)* | report + table (read-only) |
| `--apply` | report + table → export + delete → freelist hint |
| `--vacuum` | report + table → **backup** → **compact** |
| `--apply --vacuum` | report + table → **backup** → export + delete → **compact** |
| `--apply --vacuum --no-backup` | same, but without the backup copy |
| `--no-backup` alone | same as a dry run (backup only ever matters with `--vacuum`) |

> ❗ The backup and the compaction always cover the **whole database** – `ONLY` has no
> influence on them. `ONLY` only limits which sessions are shown, exported and deleted.

---

## 📁 Files

| File | Emoji | Purpose |
|---|---|---|
| `oc-lib.sh` | 📚 | shared logic: database report, table, totals, backup, `--apply`, `--vacuum` |
| `oc-prune.sh` | 🐢 | scan with `opencode session list` per directory (shows progress) |
| `oc-prune-db.sh` | 🐇 | scan with a single `SELECT` (0 s instead of ~70 s) |
| `.env` | 🔐 | local configuration (gitignored), see `.env.example` |
| `.env.example`, `.gitignore` | 🛡️ | template and protection against publishing personal paths |
| `README.md` | 📖 | this file |
| `AGENTS.md` | 🤖 | instructions for AI agents working in this repository |

Both scripts print the same table. The database variant is faster **and** more complete:
a directory scan cannot find sessions in deleted or renamed directories (the `cd` fails)
and misses sessions when one directory holds two projects. Such sessions are added back
by `oc_augment_missing` in both scripts.

---

## ⚙️ Configuration

**Precedence: environment variable → `.env` → default.** Read as `ROOT`, `DAYS`, `MIN`,
`BACKUP`, `DB`, `ONLY`, `SIZES`, `SIZE_CACHE`.

| Variable | 🟢 Default | 📝 Meaning |
|---|---|---|
| `ROOT` | `$HOME/Code` | root that gets scanned; rows outside get `outside` |
| `DAYS` | `30` | sessions older than that are candidates for deletion |
| `MIN` | `3` | this many youngest sessions stay per directory |
| `BACKUP` | `$HOME/opencode-export` | receives the exports of deleted sessions **and** (with `--vacuum`) the full database copy `opencode-<timestamp>.db`; the directory must already exist |
| `DB` | `~/.local/share/opencode/opencode.db` | opencode database |
| `ONLY` | *(empty)* | work on this directory (and everything below) only |
| `SIZES` | `1` | `0` skips the size computation (the `MB` column stays `-`) |
| `SIZE_CACHE` | `~/.cache/oc-prune/db-data.tsv` | cache for the size computation |
| `ENV_FILE` | `./.env` | path of an alternative `.env` |

`.env` lives next to the scripts (`KEY=VALUE`, `#` lines are comments):

```
BACKUP=$HOME/opencode-export
#ONLY=/home/user/projects/demo-app
```

💡 **Tip:** run with `SIZES=0` while you only want a fast overview.

---

## 🚀 Deleting sessions

Only with the `--apply` flag:

```bash
# 1️⃣  check first
ONLY=/home/user/projects/legacy-tool ./oc-prune-db.sh

# 2️⃣  delete when all opencode instances are closed
ONLY=/home/user/projects/legacy-tool ./oc-prune-db.sh --apply
```

What happens:

1. 🛑 `pgrep -x opencode` – if an instance is still running the script exits with code 1.
2. 📤 `Export to: …` is printed and the directory is created.
3. 📦 Per session: `opencode export <id> > $BACKUP/<directory>/<id>.json`, then and only
   then `opencode session delete <id>`. An empty export aborts the run **before**
   anything has been deleted.
4. 🧬 Subagent sessions of missing directories run first, then the top-level sessions.
5. 📊 at the end: `Freelist after delete: X` plus a hint that the file itself did not
   shrink – and how to get the space back.

> ❗ Without `--apply` nothing is exported and nothing is deleted.

---

## 🗜️ Reclaiming disk space

**opencode never shrinks its database itself.** The file is created with
`auto_vacuum = NONE`, no release runs a `VACUUM`, and `opencode db` is only a query
shell. Deleted sessions therefore only mark pages as *reusable inside the file*
(`freelist` in the header) – the size on disk stays exactly the same until you compact
it.

```bash
./oc-prune-db.sh --vacuum             # opencode must be closed
./oc-prune-db.sh --apply --vacuum     # backup, delete, then compact
./oc-prune-db.sh --apply --vacuum --no-backup   # without the backup copy
```

The exact step list of every command is in
[🧭 Command reference](#-command-reference); the essentials of `--vacuum`:

- 💾 it starts with a **verified full copy** of the database in `$BACKUP`
  (`opencode-<timestamp>.db`, copied with the read-only backup API)
- 📏 it **aborts** unless the database filesystem has **2×** the file size free
- 🗜️ it compacts with `VACUUM INTO` and only swaps the file in after the copy
  passed an `integrity_check`
- 💬 in a terminal it **asks** when the disk is too small for the 2× reserve –
  see the next section

### When the disk is too small

Sometimes the disk simply cannot hold the reserve (a 5 GiB database on a disk with
5.5 GiB free is the typical case). In a terminal `--vacuum` then asks:

```
  Not enough free space for the normal route: a vacuum can need up to
  twice the file size (10.83 GiB), only 5.47 GiB is free.
  Compact via /mnt/backup/opencode instead: the copy travels over the network and the
  database is overwritten in place, so locally only the size of the
  compacted copy (up to 5.41 GiB) is needed – 5.47 GiB is free.
  Do it via the backup target? [y/N]
```

On `y` the route is: checkpoint → `integrity_check` → `VACUUM INTO $BACKUP/vacuum-<ts>.db`
→ `integrity_check` on that copy → `cp` it over the database (which frees the old
pages first) → `integrity_check` again → remove the temporary copy. The local peak is
the size of the **compacted** copy instead of 2× the original – which is exactly the
space that was missing. On `n` (or without a terminal, e.g. in a script) the run stops
and nothing is changed.

> ⚠️ During the copy the local database *is* the new file – if that copy dies halfway
> the verified file on the backup target is the way back:
> `cp $BACKUP/vacuum-<ts>.db ~/.local/share/opencode/opencode.db`

What the tail of a full run looks like:

```
Backup:
  to /mnt/backup/opencode | size 4.59 GiB | free there 9.49 TiB
  copying … done
  /mnt/backup/opencode/opencode-20261014-221530.db (integrity ok, 96s)
Export to: /mnt/backup/opencode
deleting [1/267] ses_… (/home/user/projects/legacy-tool) … deleted
…
Freelist after delete: 1.33 GiB – the file itself does not shrink

Vacuum:
  before 4.59 GiB | free on disk 9.54 GiB | reserve 9.18 GiB
  integrity check … ok
  VACUUM INTO opencode.db.vac … done
  after  3.26 GiB (freed 1.33 GiB)
```

### Why not a plain `VACUUM`?

| | `VACUUM` (plain) | `VACUUM INTO` (what we do) |
|---|---|---|
| 💿 Worst case free space | up to **2×** the file size | only the **compacted copy** |
| 🛟 If it fails halfway | original already rewritten | original untouched until the swap |
| 📏 What we reserve | **2×** – we check for it and abort early | same rule, so the worst case is covered |

### How much is really left?

Deleting 2/3 of the sessions does **not** free 2/3 of the file – a real example:

| | |
|---|---|
| 🗑️ deleted (368 sessions incl. subagents) | 1.43 GB |
| 📅 still there, younger than `DAYS` | **3.16 GB** (98.4 % of what remains) |
| 🔒 still there, old but within `MIN` | 0.05 GB |
| 📚 indexes and page overhead | ~0.3 GB |

Almost everything that stays is **recent sessions** – the rule only looks at `DAYS`.
And their weight is not the messages themselves but their history: `message.updated`
events store a **full snapshot on every update** (114k snapshots of 31.5k messages ≈
3.7 GB, while the `message` table holds only 0.24 GB).

💡 Want less than 3.3 GiB left over? Use a smaller `DAYS`, or hit one heavy directory:
`ONLY=/path/to/heavy-project ./oc-prune-db.sh`. Removing the snapshot history itself is
*compaction*, not vacuuming – upstream is working on that
([#41711](https://github.com/anomalyco/opencode/pull/41711),
[#31526](https://github.com/anomalyco/opencode/issues/31526)).

---

## 🗄️ Database access

Every report, scan and table uses `sqlite3 -readonly` (plus `PRAGMA cache_size=8000`),
and so does the backup copy (`sqlite3 -readonly "$DB" ".backup …"`). The **one
exception is `--vacuum`**, which opens the database writable for the checkpoint and
the `VACUUM INTO` – nothing else ever writes to it. Besides our own size cache under
`~/.cache/oc-prune/` and the files under `$BACKUP` nothing else is created.

The `MB` values need a full scan of the `event` table (4 GiB, about 60 s) and are
therefore cached; the key is `count/max(time_created)` so the cache stays valid while
opencode is working. Later runs then take about **0 s** (without the directory scan).

| | First run | Later runs |
|---|---|---|
| ⏱️ Time | ~60 s 🐢 | ~0 s 🚀 |
| 💾 Cache | written to `SIZE_CACHE` | read from `SIZE_CACHE` |

---

## 🧰 Requirements

- 🐚 bash ≥ 4.4
- 📊 `jq`
- 🗄️ `sqlite3` ≥ 3.33 (for `-json`)
- 🤖 `opencode` in `PATH`
- 🔑 read access to the database (`--vacuum` needs write access to it)
- 📐 `df`, `stat`, `pgrep` (standard coreutils / procps)

---

## ⚠️ Gotchas

| ⚠️ Trap | ✅ Solution |
|---|---|
| 💥 `CAST(data AS BLOB)` over the 4 GiB `event` table gets killed by the OOM killer | use `length(data)` (counts characters, slightly underestimates multi-byte characters) plus `PRAGMA cache_size=8000` (otherwise ~3 GiB RSS, with it ~1,3 GiB) |
| 🚫 `GROUP BY 1` with aggregates in the same select list is forbidden in SQLite | `GROUP BY <column>` |
| 📤 Progress messages on stdout corrupt `SESSIONS=$(…)` | print them with `printf … >&2` |
| 🎯 `pgrep -f 'opencode'` also matches `vim opencode.json` and our own command line (`…/opencode-prune/…`) | `pgrep -x opencode` |
| 💥 a plain `VACUUM` wants twice the file size as free space and can fail halfway through | we **reserve 2×** (hard check before anything happens) but compact with `VACUUM INTO` + swap, so the original survives a failure – and a verified copy sits in `$BACKUP` already |
| ☠️ a leftover `-wal` from the old file applied to the new one would corrupt it | the checkpoint empties the WAL first (checked), afterwards `-wal`/`-shm` are removed |
| 📡 writing the backup onto an unmounted path would silently fill `/` | `$BACKUP` must already exist, otherwise the run stops before copying anything |
| 📉 the disk is too small for the 2× reserve (typical for a big database) | in a terminal `--vacuum` asks whether to compact via `$BACKUP` instead; scripts abort and have to free space themselves |

---

Made with ❤️ for tidying up a very full opencode database.
