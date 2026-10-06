# 🧹 opencode-prune

> Clean up sessions in the opencode database – **the analysis (dry run) is the default**,
> deleting only happens with `--apply`.

| | |
|---|---|
| 🏃 Dry run first | `./oc-prune-db.sh` – nothing is modified |
| 💥 Delete | `./oc-prune-db.sh --apply` – export, then delete |
| 🗜️ Compact | `./oc-prune-db.sh --vacuum` – give the freed pages back to the disk |
| 🔒 Database | read-only (`sqlite3 -readonly`), the only exception is `--vacuum` |
| 📦 Export | every session is exported to `BACKUP` **before** it is deleted |

---

## 📑 Contents

- [✨ What you get](#-what-you-get)
- [🗑️ Deletion rules](#-deletion-rules)
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

## 📁 Files

| File | Emoji | Purpose |
|---|---|---|
| `oc-lib.sh` | 📚 | shared logic: database report, table, totals, `--apply` |
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
| `BACKUP` | `$HOME/opencode-export` | export target before deleting |
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
./oc-prune-db.sh --apply --vacuum     # delete first, then compact
```

What `--vacuum` does, in order:

1. 🛑 refuses to run while an `opencode` process exists
2. 💾 checks that the filesystem has at least the size of the database free
3. 🧽 `PRAGMA wal_checkpoint(TRUNCATE)` and `PRAGMA integrity_check`
4. 🗜️ `VACUUM INTO '$DB.vac'` – a *copy*, the original stays untouched if anything fails
5. ✅ `integrity_check` on the copy, then it replaces the original (the old
   `-wal`/`-shm` go with it) and `journal_mode=wal` is restored
6. 📉 prints `before`, `after` and what was freed

The flag always works on the whole database – `ONLY` has no influence on it.

### Why not a plain `VACUUM`?

| | `VACUUM` (plain) | `VACUUM INTO` (what we do) |
|---|---|---|
| 💿 Free space needed | up to **2×** the file size | only the **compacted copy** |
| 4.6 GiB database | ≈ 9.2 GiB – with 9.5 GiB free that is gambling | ≈ 3.3 GiB |
| 🎯 Original file | rewritten in place | untouched until the final swap |

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

Every report, scan and table uses `sqlite3 -readonly` (plus `PRAGMA cache_size=8000`).
The **one exception is `--vacuum`**, which opens the database writable for the
checkpoint and the `VACUUM INTO` – nothing else ever writes to it. Besides our own
size cache under `~/.cache/oc-prune/` no other file is created.

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
| 💥 a plain `VACUUM` wants twice the file size as free space and can fail halfway through | `VACUUM INTO` + swap: only the compacted copy is needed, the original stays intact on failure |
| ☠️ a leftover `-wal` from the old file applied to the new one would corrupt it | the checkpoint empties the WAL first (checked), afterwards `-wal`/`-shm` are removed |

---

Made with ❤️ for tidying up a very full opencode database.
