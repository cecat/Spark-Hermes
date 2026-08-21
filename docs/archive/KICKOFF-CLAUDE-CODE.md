# Kickoff: running the Gandalf bring-up with Claude Code on the Spark

This file holds (1) the prompt to paste into Claude Code (Opus 4.8) on the DGX Spark, and
(2) how to launch Claude Code for unsupervised execution. Run it **as user `catlett`**
(not root/sudo), from inside this cloned repo.

---

## 1. The prompt (paste into Claude Code)

```
You are Claude Code (Opus 4.8) on the DGX Spark (spark-ts). Your job is to bring up a new
agent named "Gandalf" per a written plan, executing autonomously end to end.

YOUR SPEC. Read PLAN-NemoClaw-Hermes-Gandalf.md in this repo (Spark-Hermes) in full — it is
the authoritative, step-by-step plan. Follow its operating rules (Section 0) and execute
Phases A–H in order, honoring every PASS gate. Do not skip gates. On any gate failure, stop,
write the failure to ~/gandalf-bringup/RUNLOG.md, and do not proceed.

GET UP TO SPEED FIRST (read-only):
- This repo's COMPARISON-Enhancements-Lessons-vs-Hermes-NemoClaw.md and
  PLATFORM-OPTIONS-2026.6.md — why we chose NemoClaw+Hermes and what each layer replaces.
- ~/code/spark-ai/ — especially config.yaml, CLAUDE.md, and start-all.sh, for how the
  argo-shim (Anthropic-compatible endpoint at 127.0.0.1:44497, model claudesonnet46,
  identity "catlett") and vLLM (Qwen on localhost:8000) work. Phase D depends on these.
- ~/code/spark-ai-agents/docs/CONTAINMENT.md and the luoji/ and cecat/ workspaces — for
  tone/posture reference ONLY. Gandalf is a fresh, minimal agent per the plan; do NOT port
  their full duties.
- ~/code/OpenClaw-Tutorial/ — background lessons if useful.

CRITICAL CONSTRAINTS (from the plan, restated):
- This stack (NemoClaw / OpenShell / Hermes) is ALPHA and changes fast. Do NOT trust
  commands from memory. At the start of each phase, fetch the live docs linked in the plan
  and reconcile any drift before running anything; note deviations in RUNLOG.
- NON-DESTRUCTIVE: do not modify the existing OpenClaw 4.2 stack or ~/code/spark-ai*.
  Argo-shim and vLLM are shared services — connect/read only, never restart them.
- Verify all Section 1 kickoff inputs are present before Phase A; if any are missing, halt
  and list them.
- SECRETS: never print token values; store only where the docs specify.
- Keep ~/gandalf-bringup/RUNLOG.md updated with every step, command, result, and observed
  version (NemoClaw, OpenShell, Hermes).
- Some steps may need me (the human) — e.g., Google OAuth browser consent if no valid
  token.json is pre-placed. If you hit one, stop, post a single precise request, and wait.

Begin with Phase A (preflight & discovery). Work autonomously; stop only for a failed gate
or a genuine human-input requirement. When finished, write ~/gandalf-bringup/HANDOFF.md per
Phase H.
```

---

## 2. How to launch Claude Code for unsupervised execution

**Run as `catlett`, never root/sudo.** Claude Code refuses to start in unattended mode under
root/sudo. (Individual `sudo` commands the plan runs are fine.)

**Use a persistent terminal** so an SSH drop doesn't kill a multi-hour run:

```bash
cd ~/code/Spark-Hermes            # wherever you cloned it
tmux new -s gandalf               # or: screen -S gandalf
claude --dangerously-skip-permissions --model opus
# then paste the prompt above. Use /model to confirm Opus 4.8 if needed.
```

`--dangerously-skip-permissions` ≡ `--permission-mode bypassPermissions`: every tool call
(file writes, bash, network, installs) runs with no prompt. This is the realistic choice for
THIS plan because the NemoClaw installer is `curl … | bash`, which the safer "auto" mode
blocks by default (see below).

**Safety belt (recommended): deny edits to the existing stack.** Deny rules apply even in
bypass mode. Put this in `~/.claude/settings.json` (or `.claude/settings.json` in this repo)
so Claude Code physically cannot modify your live system while it works:

```json
{
  "permissions": {
    "deny": [
      "Edit(/home/catlett/code/spark-ai/**)",
      "Write(/home/catlett/code/spark-ai/**)",
      "Edit(/home/catlett/code/spark-ai-agents/**)",
      "Write(/home/catlett/code/spark-ai-agents/**)"
    ]
  }
}
```

(Reads still work, so the agent can consult those repos for context.)

**To be truly hands-off**, satisfy every Section 1 input before you start — including a
pre-authorized Google `token.json` — otherwise the run will pause at Phase F for the one
browser-consent step that can't be automated.

### Why not "auto" mode or headless `-p`?
- **auto mode** (Opus 4.8 supports it) adds a background classifier that blocks risky actions
  — but it blocks `curl | bash` and sandbox network requests by default, so this install plan
  would stall and need manual retries. Great for everyday work; wrong for this installer.
- **headless `-p`** aborts the session when an action is blocked or when human input is
  needed. This plan has deliberate human-in-the-loop gates (OAuth), so run it **interactive
  in tmux**, not `-p`, so you can answer those without restarting.

> Note: `--dangerously-skip-permissions` offers no protection against prompt injection or
> unintended actions — it runs everything. It's acceptable here because it's your own
> experimental Spark, the plan is non-destructive to the existing stack (enforced by the deny
> rules above), and the agent it builds is itself sandboxed by OpenShell. Claude Code on the
> host, however, is unconstrained — which is why the deny rules are worth adding.

Source for flags/modes: https://code.claude.com/docs/en/permission-modes
