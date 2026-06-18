# Ops — day-2 operations

"I want to change X." Read this table, run the script or follow the runbook.

| I want to… | Run this |
|---|---|
| See if Gandalf is healthy | `bash status.sh` |
| Push my updated `gandalf/memories/*.md` to the running agent | `bash apply-memories.sh` |
| Push my updated `gandalf/skills/*/SKILL.md` to the agent | `bash apply-skills.sh` |
| Update scheduled jobs after editing the `cron:` block in `~/.hermes/config.yaml` | `bash apply-cron.sh` |
| Apply custom OpenShell network policies from `bringup/50-openshell-policies/` | `bash apply-policies.sh` |
| Change the inference model/provider after editing the `inference:` block in `~/.hermes/config.yaml` | `bash set-inference.sh` |
| Re-authorize Google (token expired/revoked) | `bash reauth-google.sh` |
| Take a snapshot before something risky | `bash snapshot.sh <reason>` |
| Rotate the Slack tokens | [`rotate-slack-tokens.md`](rotate-slack-tokens.md) |
| Tighten the sandbox's network policy (Phase H follow-up) | [`tighten-network-policy.md`](tighten-network-policy.md) |
| Add a new skill | [`add-a-skill.md`](add-a-skill.md) |

## Common conventions

- All apply scripts are **idempotent** — safe to re-run when you're unsure if a change went through.
- Apply scripts validate prereqs (sandbox running, env vars set, sudo cached if needed) and exit early with clear errors if something's missing.
- After any change that affects the running sandbox, the script polls the gateway log for ~10 seconds to confirm health. If anything looks like a crash loop, the script aborts and tells you how to investigate.
- Apply scripts NEVER touch the host's `~/code/spark-ai*` (the OpenClaw stack — protected by `.claude/settings.json` deny rules even when run via Claude Code).
- All secrets stay in `~/.hermes/.env` or `~/.config/gogcli/`; nothing in this directory writes secrets to the repo.

## What's NOT here

Initial bringup scripts. Those live in [`../bringup/`](../bringup/). Once Gandalf is running, you should never need to revisit anything in `bringup/` except the policy YAMLs and the systemd units (both of which `apply-policies.sh` and `bringup/40-vllm-bridge/README.md` cover).
