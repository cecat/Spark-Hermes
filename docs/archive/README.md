# docs/archive — historical, superseded, do not act on

Documents here are kept for provenance. **Nothing here reflects current state,
and none of it should be used to plan work.**

Most of it describes **how Gandalf was originally brought up in June 2026**.
Archived 2026-08-20, because a session trying to "come up to speed" burned its
whole context window on stale planning documents and inherited wrong premises
from them.

| File | What it was | Why it is dead |
|---|---|---|
| `PLAN-NemoClaw-Hermes-Gandalf.md` | The original bring-up plan (2026-06-16), written to run unattended | Executed and finished in June 2026. Describes a system that no longer exists in that shape — no FALDA, no Sibline, no Telegram, no soul/ directory. |
| `KICKOFF-CLAUDE-CODE.md` | The prompt used to launch the bring-up | One-time kickoff for the plan above. Points at `PLAN-NemoClaw-Hermes-Gandalf.md`, a repo-root path that no longer exists. |
| `Initial-Setup-Summary.md` | Snapshot of what existed right after bring-up (2026-06-20) | A point-in-time snapshot, two months stale. `README.md` + `CLAUDE.md` are the live description. |
| `HANDOFF-2026-08-20-openclaw-migration.md` | First cecat/luoji migration plan (2026-08-20, morning) | Superseded the same day by `docs/HANDOFF-2026-08-20b-cecat-migration.md`. Two of its premises are now known false: `--host-mount` does not exist on v0.0.55 (so its "irreversible Step 2 decision" is void), and its Step 1/2 were completed. Its landmines and Steps 4–6 were carried forward into 20b. |

## rejected/

`rejected/` holds implementations that were built, evaluated, and NOT adopted.
They are kept so a future session can see what was already tried and why it was
dropped, instead of rebuilding it. See the rejecting document for the reasoning —
for `shuttle-cecat.sh`, that is
`docs/HANDOFF-2026-08-20b-cecat-migration.md` → "Rejected: the host-side shuttle".

## Where to look instead

- **The live cecat/luoji migration plan** → `docs/HANDOFF-2026-08-20b-cecat-migration.md`
- **Current state and how to operate it** → `README.md`, `CLAUDE.md`
- **What Hermes actually loads** → `docs/HERMES-LOAD-PATHS.md` (still live —
  verified against source, and the reason `memories/` was replaced by `soul/`)
- **Open work and decisions** → `docs/FOLLOWUPS.md`
- **Why the platform upgrade is blocked** → `docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md`
- **Historical incident narrative** → `runlog/` (append-only; also historical,
  but organised by date and still useful for "why is it like this?")

## A caution about the June runlogs

`runlog/RUNLOG-2026-06-17-bringup.md` and `runlog/HANDOFF-2026-06-18.md` cite
`~/code/Spark-Hermes/PLAN-NemoClaw-Hermes-Gandalf.md`. That path was already
wrong before this archive move (the file lived in `docs/`, not the repo root).
The runlogs are deliberately left unedited — they are an append-only record of
what was believed at the time.
