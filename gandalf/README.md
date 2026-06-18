# Gandalf — personality and procedures

This directory is what makes Gandalf *Gandalf* rather than a generic Hermes agent. Two parts:

| | Hermes term | What it is | When loaded |
|---|---|---|---|
| [`memories/`](memories/) | **memories** | Small declarative-fact Markdown files | Auto-injected into every turn |
| [`skills/`](skills/) | **skills** | Per-task runbooks with a `SKILL.md` | Loaded on demand based on `tags` |

## Edit & apply loop

Edit a file in this repo. Then push to the running sandbox:

- `bash ../ops/apply-memories.sh` — pushes `memories/` to `/sandbox/.hermes/memories/`
- `bash ../ops/apply-skills.sh` — pushes `skills/` to `/sandbox/.hermes/skills/`

The repo is source of truth. The sandbox is where the running agent reads from. Apply scripts make those agree.

## memories/ — the writing style that works

Hermes reads memories on every turn. **Declarative facts**, not imperative instructions:

- ✓ "Charlie prefers concise responses"
- ✗ "Always respond concisely"

The first phrasing gets re-read as a *fact about the world*; the second gets re-read as a *directive to do right now*, which can collide with whatever you actually asked Gandalf to do this turn.

Keep memories small (a few dozen lines each). Name them with a leading number so the loading order is obvious (`00-identity.md` loads before `30-guardrails.md`).

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

To bring on a new skill, see [`../ops/add-a-skill.md`](../ops/add-a-skill.md).

## When in doubt

If something Gandalf-specific would either help or hurt depending on context, it's usually a **skill** (loaded on demand). If it's true regardless of what he's doing right now, it's a **memory** (always loaded).
