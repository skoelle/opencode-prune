# 🧹 opencode-prune

> Clean up sessions in the opencode database – **the analysis (dry run) is the default**,
> deleting only happens with `--apply`.

| | |
|---|---|
| 🏃 Dry run first | `./oc-prune-db.sh` – nothing is modified |
| 💥 Delete | `./oc-prune-db.sh --apply` – export, then delete |
| 🔒 Database | read-only (`sqlite3 -readonly`), only a local size cache is written |
| 📦 Export | every session is exported to `BACKUP` **before** it is deleted |

---

## 📑 Contents

- [✨ What you get](#-what-you-get)
- [🗑️ Deletion rules](#-deletion-rules)
- [📁 Files](#-files)
- [⚙️ Configuration](#-configuration)
- [🚀 Deleting sessions](#-deleting-sessions)
- [🗄️ Database access](#-database-access)
- [🧰 Requirements](#-requirements)
- [⚠️ Gotchas](#-gotchas)

---

## ✨ What you get

```
Database (read-only): $HOME/.local/share/opencode/opencode.db
  file 4.59 GiB | WAL 59.1 MiB | free inside 0 B (0.0 %)
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
| 🏭 | **Table sizes** (`event`, `part`, `message`, `session`) and free space inside the file |
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

> ❗ Without `--apply` nothing is exported and nothing is deleted.

---

## 🗄️ Database access

Every access uses `sqlite3 -readonly` (plus `PRAGMA cache_size=8000`). Only our own size
cache under `~/.cache/oc-prune/` is ever written to.

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
- 🔑 read access to the database

---

## ⚠️ Gotchas

| ⚠️ Trap | ✅ Solution |
|---|---|
| 💥 `CAST(data AS BLOB)` over the 4 GiB `event` table gets killed by the OOM killer | use `length(data)` (counts characters, slightly underestimates multi-byte characters) plus `PRAGMA cache_size=8000` (otherwise ~3 GiB RSS, with it ~1,3 GiB) |
| 🚫 `GROUP BY 1` with aggregates in the same select list is forbidden in SQLite | `GROUP BY <column>` |
| 📤 Progress messages on stdout corrupt `SESSIONS=$(…)` | print them with `printf … >&2` |
| 🎯 `pgrep -f 'opencode'` also matches `vim opencode.json` and our own command line (`…/opencode-prune/…`) | `pgrep -x opencode` |

---

Made with ❤️ for tidying up a very full opencode database.
