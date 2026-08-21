# Spark-Hermes

A always-on personal-assistant AI agent named **Gandalf**, running on a NVIDIA DGX Spark.

The stack: **Hermes Agent** (Nous Research, MIT) inside an **NVIDIA OpenShell** sandbox, managed by **NemoClaw**. Local inference via **vLLM** (Qwen3-Coder-Next-FP8). Talks to Slack, Gmail, and Google Drive.

This repo is everything needed to:
- Stand up the system from a fresh DGX Spark host.
- Change what Gandalf knows, does, and can reach.
- Operate it day-to-day without remembering arcane commands.

For background on *why* this stack (rather than OpenClaw, or n8n, or rolling your own), see [docs/PLATFORM-OPTIONS-2026.6.md](docs/PLATFORM-OPTIONS-2026.6.md) and [docs/COMPARISON-Enhancements-Lessons-vs-Hermes-NemoClaw.md](docs/COMPARISON-Enhancements-Lessons-vs-Hermes-NemoClaw.md).

## Related repos

Four repos, split by ownership. The boundary is deliberate: shared substrate
below, per-agent integration above.

| Repo | What lives there |
|---|---|
| **`spark-fabric`** | Shared substrate: FALDA, embedder, distiller, NATS/Sibline, UMP |
| **`Spark-Hermes`** *(this one)* | **Gandalf** — Hermes agent + gateway in an NVIDIA OpenShell sandbox, his `soul/` and `skills/`, egress policies, ops scripts |
| **`spark-ai`** | OpenClaw gateway + vLLM. Shared services — connect/read only, never restart |
| **`spark-ai-agents`** | **Luoji** — OpenClaw agent folders, runbooks, and notes |

---

## I just cloned this. Now what?

### Stand up a fresh Gandalf from scratch
You're a new operator on a fresh DGX Spark. Read [`bringup/README.md`](bringup/README.md) and walk through the numbered files. About 30–60 minutes once prereqs are in place.

### Change what Gandalf knows about itself, you, or its duties
Edit a file in [`gandalf/soul/`](gandalf/soul/), then run:
```
bash ops/apply-soul.sh
```
These files are concatenated into `~/.hermes/SOUL.md`, which Hermes injects into
the system prompt every session. Changes land on the next new session (`/new` in
a chat) — no gateway restart. Use `--dry-run` to preview.

> Formerly `gandalf/memories/` + `apply-memories.sh`, which pushed to a directory
> Hermes never reads. See [`docs/HERMES-LOAD-PATHS.md`](docs/HERMES-LOAD-PATHS.md)
> for what actually loads, and verify before inventing a new location.

### Add a runbook (procedure) Gandalf should follow
Add a directory under [`gandalf/skills/`](gandalf/skills/) with a `SKILL.md`, then run:
```
bash ops/apply-skills.sh
```
See [`ops/add-a-skill.md`](ops/add-a-skill.md).

### Change the inference model or provider
Edit the `inference:` block in `~/.hermes/config.yaml`, then:
```
bash ops/set-inference.sh
```

### Schedule a new cron job
Edit the `cron.jobs:` list in `~/.hermes/config.yaml`, then:
```
bash ops/apply-cron.sh
```

### Renew Google OAuth (token expired or revoked)
```
bash ops/reauth-google.sh
```
See [`ops/reauth-google.sh`](ops/reauth-google.sh) for the workflow.

### Check Gandalf is healthy
```
bash ops/status.sh
```

### Make a snapshot before risky changes
```
bash ops/snapshot.sh pre-experiment
```

---

## Directory layout

| Directory | What lives here |
|---|---|
| `docs/` | Reference and open items. **Start with [`docs/FOLLOWUPS.md`](docs/FOLLOWUPS.md).** Note: session handoffs (`HANDOFF-*.md`), plans (`PLAN-*.md`) and `DECISION-*.md` are gitignored working notes — they exist on the host but are deliberately not published, since this repo is public. Durable conclusions get folded into this README, `CLAUDE.md`, `docs/FOLLOWUPS.md`, or a dated `runlog/` entry. |
| `bringup/` | One-time install from a fresh host (numbered 00, 10, 20…) |
| `gandalf/` | Gandalf's personality (`soul/` → `SOUL.md`) and procedures (`skills/`) — edit these to change his behavior |
| `ops/` | Apply scripts and runbooks for day-2 operations |
| `runlog/` | Historical record of how Gandalf was first built (and what we learned) |

Configuration lives **outside** the repo at `~/.hermes/config.yaml` (identifiers and tunables — gitignored, host-specific) and `~/.hermes/.env` (mode 600, raw secrets). Templates for both are in `bringup/`.

Each subdirectory has its own `README.md` describing what's there and how it's used.

---

## What's NOT in this repo

- **`~/.hermes/config.yaml`** — deployment identifiers (Slack channel/user IDs, GCP project, model choice, cron jobs). Mode 644 on the host. Template: [`bringup/config.example.yaml`](bringup/config.example.yaml).
- **`~/.hermes/.env`** — raw Slack tokens; mode 600 on the host. Template: [`bringup/secrets.example.env`](bringup/secrets.example.env).
- **`~/.config/gogcli/`** — OAuth state for the `gog` CLI used during initial Google auth.
- **`~/gandalf-bringup/`** — scratch directory from the original install; archived contents are at `~/gandalf-bringup/archive/` for historical reference.
- **NemoClaw snapshots** — at `~/.nemoclaw/rebuild-backups/gandalf/`. Managed by `ops/snapshot.sh`.

The repo never holds secrets. Real credentials stay on the host filesystem with restrictive permissions.

### This repo is public — keep deployment identifiers out of it

Credentials are handled (gitignored, mode 600). The easier mistake is pasting a
real **identifier** into prose: a Slack user/channel ID, a Telegram chat ID, a
workspace name. They are not credentials — useless without a token — but they
identify a specific person and workspace, and a push is not reversible.

- **`gandalf/soul/*.md` and skills:** never inline a real value. Reference it as
  `${operator.name}`, `${telegram.group_chat}`, etc.; `ops/apply-soul.sh`
  substitutes from `~/.hermes/config.yaml` at push time, so the agent sees real
  values while the repo stores only the key. Add the key to config.yaml (and to
  `bringup/config.example.yaml` as a placeholder) rather than hardcoding.
- **`runlog/` and HANDOFF notes:** this is where identifiers actually leak,
  because runlogs quote real commands and env lines. Write
  `SLACK_HOME_CHANNEL=<home-channel-id>` instead of the literal value. The
  narrative reads the same; the ID is what has to stay behind.

Some IDs from the June 2026 runlogs are already published. They are identifiers
rather than credentials, and rewriting history would not un-publish them — so
the rule is forward-looking, not a cleanup task.

---

## "Gateway" means three different things

Worth pinning down before reading anything else here, because conflating these
leads to wrong conclusions about what is shared between agents.

| Layer | What it is | Cardinality |
|---|---|---|
| **Agent runtime gateway** | Hermes' (or OpenClaw's) own process — the LLM loop. Runs *inside* the sandbox; Hermes listens on 8642. | one per sandbox, fully independent |
| **OpenShell control plane** | Usually what "gateway" means. Sandbox lifecycle, L7 egress proxy, `inference.local` routing, port forwards. Multi-gateway capable (`openshell gateway list`). | many possible |
| **NemoClaw's pinned instance** | NemoClaw v0.0.55 hardcodes itself to one control plane named `nemoclaw`. Later versions parameterise it via `NEMOCLAW_GATEWAY_PORT`. | one, on v0.0.55 |

The consequence that matters: a sandbox's model traffic goes to
`https://inference.local/v1`, a virtual host with **no DNS entry** — the L7 proxy
intercepts it and routes it per the *control plane's* inference route. Two
sandboxes on the same control plane therefore share one inference route and (on
v0.0.55) one registry file, even though their agent runtimes are separate
processes that never talk to each other.

So "each agent has its own gateway" is true at the runtime layer and misleading at
the control-plane layer. Isolating agents means separate control planes, not
separate agent runtimes.

## Versions known to work

- NemoClaw / nemohermes: `v0.0.55` — what the CLIs report. The npm package
  version is `0.1.0`, which is what earlier notes here recorded; both refer to
  the same install.
- OpenShell: `0.0.44`
- Hermes Agent: `v2026.5.16` — reports as `Hermes Agent v0.14.0 (2026.5.16)`,
  i.e. semver *and* calendar. Newer NemoClaw reads the semver.
- Sandbox image base: `ghcr.io/nvidia/nemoclaw/hermes-sandbox-base:latest` (digest pinned in NemoClaw blueprint)
- Host: Ubuntu 24.04, Docker 28+, NVIDIA GB10

These are alpha-stage projects that move quickly. See `bringup/README.md` for the drift-handling rule.

**Do not upgrade these yet.** NemoClaw `v0.0.110` cannot onboard or rebuild a
sandbox on this host — its preflight misidentifies our Dell-branded GB10 and
fails closed. Decision, evidence, and the re-test trigger are in
[`docs/FOLLOWUPS.md`](docs/FOLLOWUPS.md); the upstream bug report is in
[`docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md`](docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md).

---

## License

TODO — pick MIT or similar. The agent stack components (Hermes MIT, NemoClaw/OpenShell Apache-2.0) are permissive.
