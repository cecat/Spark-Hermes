# Step 2 (P3-2) — the `/shared` mechanism for cecat under OpenShell

**Decided 2026-08-20.** Verification method: `--help` output *and* the v0.0.55 /
0.0.44 source trees. Nothing on the host was changed.

> **PARTIALLY REVISED later the same day.** The "Finding" and "Options" sections
> below are verified and stand. The **Decision** section does not: its polling
> shuttle was built, rejected, and deleted (see
> `docs/HANDOFF-2026-08-20b-cecat-migration.md` → "Rejected: the host-side
> shuttle"). Whether something shuttle-shaped is needed at all depends on what
> an **OpenClaw** agent under NemoClaw natively provides — an open question.
> Do not implement the Decision section as written.

## Finding: the premise of Step 2 is void

The handoff says `--host-mount` is "declared at onboard time and cannot be
attached later," and flags it as the irreversible decision. **That flag does not
exist on this stack.** It was a `v0.0.110` feature described in the old
DGX-Spark plan — exactly the re-verification Step 2 asked for.

| Checked | Result |
|---|---|
| `nemoclaw onboard --help` (v0.0.55) | no `--host-mount` |
| `grep -rn 'host-mount\|hostMount' nemoclaw-src/src/` @ tag v0.0.55 | **zero matches** |
| `openshell sandbox create --help` (0.0.44) | **no bind-mount flag of any kind** |

The only file-in flag on `sandbox create` is `--upload`
(`<LOCAL_PATH>[:<SANDBOX_PATH>]`), a one-time copy at create time, not a live
mount.

This is consistent with Gandalf: his sandbox has no bind mounts, and everything
in `/sandbox/.hermes` lives in the container's writable layer.

**Consequence — the good kind:** there is no irreversible onboard-time decision
here. Nothing about `/shared` can be got wrong in a way that forces recreating
the sandbox. Step 2 does not block Step 3.

## What cecat actually needs `/shared` for

Today she has two rw bind mounts (`/workspace`, `/shared`) plus a ro `/scripts`.
Under OpenShell all three disappear. Her real traffic across the boundary:

| Direction | What | Frequency |
|---|---|---|
| host → agent | `PAUSE.global` / `PAUSE.agent.cecat` sentinels | every heartbeat (15 min) |
| host → agent | `/shared/CHANNELS.md`, `/shared/config.py` | per Slack post |
| host → agent | `/scripts/*.py`, runbooks, `CALENDAR.md` | per exec |
| **agent → host** | **`/shared/slack/outbox/*.json`** | **every notification** |
| agent → host | `/shared/logs/todos.log` appends | per READY task |
| agent ↔ both | `/workspace/TODO.md`, `memory/*`, `heartbeat-state.json` | constant |

The outbox is the load-bearing one. It is *the only way cecat speaks to Slack* —
she has no Slack egress; a host cron (`send-slack.sh`, every 5 min) drains it.
Break agent→host and she goes silent while looking healthy.

## Options, as the plan asked

**(a) Read-only host mount for host→agent** — **unavailable.** No such flag.
Nearest equivalent is `openshell sandbox upload` (what `ops/apply-soul.sh` and
`apply-skills.sh` already use). Fine for slow-changing content — runbooks,
scripts, CHANNELS.md — pushed by an apply-script. Not viable for PAUSE
sentinels, which must be observed within one heartbeat: a kill switch you have
to remember to push is not a kill switch.

**(b) `nemoclaw share mount` (SSHFS)** — present in v0.0.55
(`src/lib/share-command.ts`) but **wrong direction and not installed.** It
projects *sandbox files onto a host directory* — agent→host only. It would cover
the outbox, but not PAUSE, CHANNELS.md, or scripts. `sshfs` is also not
installed on this host, and it adds a FUSE daemon whose death silently stops
delivery. For a 24/7 agent whose only voice is the outbox, that is a bad
failure mode.

**(c) Polling shuttle — RECOMMENDED.** The pattern Gandalf's Sibline bridge
already uses on this host, and the one thing here with production evidence.

## Decision

Use **`upload` for static content + a polling shuttle for live state**, and skip
mounts entirely.

1. **Static, push at apply time** (`openshell sandbox upload`, hash-compared,
   same shape as `ops/apply-soul.sh`): runbooks, `/scripts/*.py`, `CALENDAR.md`,
   `CHANNELS.md`, `config.py`, `SOUL.md`, `USER.md`. A `ops/apply-cecat.sh`
   mirroring the existing apply-scripts.
2. **Live state, shuttle both ways** on the host's existing 5-minute cron tick:
   - agent → host: drain `/sandbox/.../slack/outbox/*.json`, hand to the
     existing `send-slack.sh`. Delivery latency is unchanged (~5 min) because
     the outbox was already cron-drained.
   - host → agent: push PAUSE sentinels and `TODO.md` READY lines in.
3. **PAUSE needs a tighter loop than 5 min.** Either shuttle sentinels on a
   1-minute tick, or invert it — have HEARTBEAT.md Step 0 fetch the sentinel
   itself. Inverting is better: the check then fails closed inside the agent's
   own turn rather than depending on a shuttle that may have died.

Rationale: no new daemon, no FUSE, no new failure mode, and it reuses transfer
machinery already proven on this host for Gandalf.

## Carried into Step 3

- `--upload` is a **create-time** flag. Whatever must exist at first boot goes in
  the onboard invocation; everything else is pushed after. Enumerate that set
  before onboarding.
- The shuttle is new code and is **not** written yet. cecat cannot notify anyone
  until it exists — write and test it before cutover, not after.
- Still blocking from Step 1 and unchanged by this decision: all four of cecat's
  HTTP scripts use `urllib`, which the L7 proxy denies.
