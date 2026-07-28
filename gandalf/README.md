# Gandalf — personality and procedures

This directory is what makes Gandalf *Gandalf* rather than a generic Hermes agent. Two parts:

| | Rendered to | What it is | When loaded |
|---|---|---|---|
| [`soul/`](soul/) | `~/.hermes/SOUL.md` | Always-on identity, facts, and hard rules | Every session (per agent construction) |
| [`skills/`](skills/) | `~/.hermes/skills/<name>/` | Per-task runbooks with a `SKILL.md` | On demand, based on `tags` |

> **This directory used to be called `memories/` and pushed files to
> `~/.hermes/memories/`. Nothing ever read them.** Hermes only auto-loads
> `MEMORY.md` and `USER.md` (hard-coded, and small), plus `SOUL.md`. The rename
> and the switch to `SOUL.md` happened 2026-07-28 after verifying the loaders in
> the Hermes source. Before inventing a new place to put agent config, read
> [`../docs/HERMES-LOAD-PATHS.md`](../docs/HERMES-LOAD-PATHS.md).

## Edit & apply loop

Edit a file in this repo. Then push to the running sandbox:

- `bash ../ops/apply-soul.sh` — concatenates `soul/*.md` (in filename order) into `/sandbox/.hermes/SOUL.md`
- `bash ../ops/apply-skills.sh` — pushes `skills/` to `/sandbox/.hermes/skills/`

The repo is source of truth. The sandbox is where the running agent reads from. Apply scripts make those agree.

`SOUL.md` is cached per agent session, so changes land on the next **new session** — send `/new` in a chat. A gateway restart is *not* required. Use `bash ../ops/apply-soul.sh --dry-run` to see exactly what will be rendered before pushing.

## soul/ — the writing style that works

The files here are concatenated in filename order into one `SOUL.md`, which is
injected whole into the system prompt. Write **declarative facts**, not
imperative instructions:

- ✓ "Charlie prefers concise responses"
- ✗ "Always respond concisely"

The first phrasing gets re-read as a *fact about the world*; the second gets re-read as a *directive to do right now*, which can collide with whatever you actually asked Gandalf to do this turn.

Name files with a leading number so the assembly order is obvious (`00-identity.md` comes before `30-guardrails.md`). Any `${a.b.c}` placeholder is substituted from `~/.hermes/config.yaml` at apply time.

**Hard size limit: 20,000 characters** for the whole concatenated file
(`CONTEXT_FILE_MAX_CHARS`). Over that, Hermes truncates the *middle* — you'd
silently lose the centre of your guardrails. `apply-soul.sh` refuses to upload
rather than let that happen. Current usage is around 8K, so there's room, but if
you approach the cap move on-demand material into a skill instead.

## skills/ — the runbook pattern

A skill is a directory with at least a `SKILL.md` file in this shape:

```markdown
---
name: my-skill-slug-must-be-unique
description: "One-sentence summary."
version: 1.0.0
metadata:
  hermes:
    tags: [keyword-that-triggers-loading]
---

# My Skill

(Markdown body — runbook steps, references, examples)
```

Hermes scans `tags` to decide when to load a skill. See `/opt/hermes/skills/productivity/google-workspace/SKILL.md` inside the sandbox for a worked example.

Skills have **no size cap**, which makes them the right home for anything long
or situational — and the right home for durable knowledge the agent authors
itself.

To bring on a new skill, see [`../ops/add-a-skill.md`](../ops/add-a-skill.md).

## When in doubt

Three homes, three jobs:

- True regardless of what he's doing right now, and short → **`soul/`** (always loaded)
- Only relevant to a specific task, or long → **`skills/`** (loaded on demand)
- Something *he* learns and writes himself → **`MEMORY.md`** via his memory tool (2,200 chars, a working set — promote recurring lessons into a skill)
