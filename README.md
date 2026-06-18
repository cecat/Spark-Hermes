# Spark-Hermes

A always-on personal-assistant AI agent named **Gandalf**, running on a NVIDIA DGX Spark.

The stack: **Hermes Agent** (Nous Research, MIT) inside an **NVIDIA OpenShell** sandbox, managed by **NemoClaw**. Local inference via **vLLM** (Qwen3-Coder-Next-FP8). Talks to Slack, Gmail, and Google Drive.

This repo is everything needed to:
- Stand up the system from a fresh DGX Spark host.
- Change what Gandalf knows, does, and can reach.
- Operate it day-to-day without remembering arcane commands.

For background on *why* this stack (rather than OpenClaw, or n8n, or rolling your own), see [docs/PLATFORM-OPTIONS-2026.6.md](docs/PLATFORM-OPTIONS-2026.6.md) and [docs/COMPARISON-Enhancements-Lessons-vs-Hermes-NemoClaw.md](docs/COMPARISON-Enhancements-Lessons-vs-Hermes-NemoClaw.md).

---

## I just cloned this. Now what?

### Stand up a fresh Gandalf from scratch
You're a new operator on a fresh DGX Spark. Read [`bringup/README.md`](bringup/README.md) and walk through the numbered files. About 30–60 minutes once prereqs are in place.

### Change what Gandalf knows about itself, you, or its duties
Edit a file in [`gandalf/memories/`](gandalf/memories/), then run:
```
bash ops/apply-memories.sh
```

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
| `docs/` | Background: plan, platform-options write-up, lessons-learned comparison |
| `bringup/` | One-time install from a fresh host (numbered 00, 10, 20…) |
| `gandalf/` | Gandalf's personality (`memories/`) and procedures (`skills/`) — edit these to change his behavior |
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

---

## Versions known to work

- NemoClaw / nemohermes: `v0.1.0`
- OpenShell: `0.0.44`
- Hermes Agent: `v2026.5.16`
- Sandbox image base: `ghcr.io/nvidia/nemoclaw/hermes-sandbox-base:latest` (digest pinned in NemoClaw blueprint)
- Host: Ubuntu 24.04, Docker 28+, NVIDIA GB10

These are alpha-stage projects that move quickly. See `bringup/README.md` for the drift-handling rule.

---

## License

TODO — pick MIT or similar. The agent stack components (Hermes MIT, NemoClaw/OpenShell Apache-2.0) are permissive.
