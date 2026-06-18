# Gandalf's skills

Empty for now. Skills get added as Gandalf takes on specific duties.

See [`../README.md`](../README.md) for the skill format and [`../../ops/add-a-skill.md`](../../ops/add-a-skill.md) for the workflow.

## Built-in skills already in the sandbox

These ship with the Hermes Agent base image and don't need to be re-added here:
- `productivity/google-workspace` — Gmail, Drive, Calendar, Docs, Sheets
- `productivity/google-workspace/references/gmail-search-syntax.md` — Gmail query operators
- Various optional skills at `/opt/hermes/optional-skills/` inside the sandbox

To see what's there: `nemohermes gandalf connect`, then `ls /opt/hermes/skills/ /opt/hermes/optional-skills/`.

## When to put a skill here vs. use a built-in

Use this directory for **anything Gandalf-specific** — your workflows, your conventions, your patterns. Don't duplicate built-ins.
