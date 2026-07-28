# What Hermes actually loads

**Verified against Hermes Agent v0.14.0 source, 2026-07-28, by reading the code — not the docs.**

This document exists because this repo spent six weeks pushing content into two
directories that no Hermes code path has ever read. If you are about to invent a
convention for "where Gandalf's rules live," read this first and verify any new
mechanism the same way: find the loader, read the call chain, then prove it with
a canary string.

---

## The map

| Path | Loaded? | Cap | When | Code |
|---|---|---|---|---|
| `~/.hermes/SOUL.md` | ✅ **yes** | 20,000 chars | per agent construction | `load_soul_md()` — `agent/prompt_builder.py:1305` |
| `~/.hermes/MEMORY.md` | ✅ yes | 2,200 chars | every turn | `MemoryStore.load_from_disk()` — `tools/memory_tool.py:126-132` |
| `~/.hermes/USER.md` | ✅ yes | 1,375 chars | every turn | same as above |
| `~/.hermes/skills/<name>/SKILL.md` | ✅ yes | none | on demand, by `tags` | skill loader |
| `agent.system_prompt` (config.yaml) | ⚠️ yes, **restart required** | — | gateway startup only | `_load_ephemeral_system_prompt()` — `gateway/run.py:2288-2307` |
| `AGENTS.md`, `CLAUDE.md`, `.cursorrules` | ✅ yes | 20,000 chars | cwd only | context-file loader |
| `~/.hermes/memories/*.md` | ❌ **NO** | — | never | nothing reads this |
| `~/.hermes/personalities/*.md` | ❌ **NO** | — | never | nothing reads this |

---

## The two dead paths

### `memories/` — numbered files are never read

`MemoryStore.load_from_disk()` opens exactly two hard-coded filenames:
`MEMORY.md` and `USER.md`. There is no glob, no numeric-prefix scan, and no
config key anywhere in Hermes (`memory.files`, `memory.dir`, `context.files` —
none exist) that would add more. Files like `00-identity.md` and
`30-guardrails.md` sitting in that directory are inert.

This repo's `ops/apply-memories.sh` faithfully uploaded them for six weeks.
It has been replaced by [`ops/apply-soul.sh`](../ops/apply-soul.sh), which
concatenates the same source files into `SOUL.md` — a path that *is* read.

### `personalities/` — not a Hermes concept

Nothing in Hermes reads a `personalities/` **directory**. The only
"personalities" mechanism is the `agent.personalities` **dict** in config.yaml,
consumed by the `/personality <name>` command to overwrite `agent.system_prompt`
in memory. A top-level `personality:` key in config.yaml is likewise consumed by
nothing.

If `/sandbox/.hermes/personalities/` exists on a host, it is drift. Harvest
anything useful in it into `gandalf/soul/`, then delete it.

---

## Choosing where to put something

**Always-on behavioural rules, identity, standing facts** → `gandalf/soul/`,
rendered to `SOUL.md` by `ops/apply-soul.sh`. 20K is generous; the four current
files use about 8K.

**Things the agent learns and writes itself** → `MEMORY.md` via its memory tool.
Only 2,200 chars, so treat it as a working set, not an archive. When a lesson
recurs, promote it into a skill.

**Task procedures and runbooks** → `gandalf/skills/<name>/SKILL.md`, pushed by
`ops/apply-skills.sh`. No size cap, loaded on demand via `tags`. This is also
where an agent's *self-authored* durable knowledge belongs.

**Avoid `agent.system_prompt`.** It works, but only reloads on gateway restart —
which drops every live conversation. It also lives in `config.yaml`, which is
covered by NemoClaw's integrity hash (`/etc/nemoclaw/hermes.config-hash`), so
editing it means recomputing that hash too. `SOUL.md` has neither problem.

---

## Activation semantics

`SOUL.md` is read by `load_soul_md()` on every call, but the assembled system
prompt is cached per `AIAgent` instance:

```
load_soul_md()                 prompt_builder.py:1305   read_text(), no cache
  -> _build_system_prompt_parts()  run_agent.py:6082
  -> _build_system_prompt()        run_agent.py:6264
  -> self._cached_system_prompt    run_agent.py:10724   cached for the session
```

Hermes deliberately never re-renders mid-session, to keep upstream prompt caches
warm. So a new `SOUL.md` takes effect on the next **new agent instance**:

- `/new` in a chat ← the cheap one
- gateway start
- context-compression rebuild
- session eviction and reload

**No gateway restart is needed.**

---

## How this was verified

Don't trust this table because it's written down — that's the mistake that
created the problem. It was established by:

1. Reading the loader and its call chain in `/opt/hermes`, not the documentation.
2. Writing a distinct canary string into each candidate path.
3. Starting a fresh session and asking for each canary cold.

`SOUL.md` returned its canary. `agent.system_prompt` did not — exactly as the
call chain predicted, because the gateway had cached an empty value at startup.

Apply the same three steps to any new mechanism before building on it.
