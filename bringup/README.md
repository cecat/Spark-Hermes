# Bringup — fresh-host install

Walk through the numbered files in order. The whole sequence takes 30–60 minutes once the prerequisites in `00-prereqs.md` are in place.

| Step | Time | What |
|---|---|---|
| [`00-prereqs.md`](00-prereqs.md) | n/a | What must exist before you start (DGX Spark, vLLM, Slack workspace, Google account) |
| [`10-install-nemoclaw.sh`](10-install-nemoclaw.sh) | ~15 min | Installs Node 22, NemoClaw, OpenShell, builds the `gandalf` sandbox |
| [`20-slack-app/`](20-slack-app/) | ~5 min | Create the Slack app from the manifest; copy the bot + app tokens |
| [`30-google-oauth.md`](30-google-oauth.md) | ~10 min | OAuth dance for Gmail/Drive/Calendar via the `gog` CLI |
| [`40-vllm-bridge/`](40-vllm-bridge/) | ~2 min | Install the two systemd-user units that bridge vLLM into the sandbox |
| [`50-openshell-policies/`](50-openshell-policies/) | ~2 min | Apply Google-egress and inference-widen policies |
| [`60-smoke-tests.sh`](60-smoke-tests.sh) | ~2 min | Verify inference, Gmail search, Drive search, Slack DM all work |

Then `bash ../ops/apply-memories.sh && bash ../ops/apply-skills.sh && bash ../ops/apply-cron.sh` to push everything from this repo into the running sandbox.

## Operating rules

This stack (Hermes/NemoClaw/OpenShell) is **alpha and changes quickly**. The exact commands here worked as of 2026-06-18 against the versions pinned in the top-level README. If a step fails:

1. Fetch the live upstream docs (NemoClaw, OpenShell, hermes-agent) before re-trying.
2. Compare flags/env vars against this repo's version.
3. If you find drift, update the relevant file here and add a note to `runlog/` describing the change.

## Gotchas worth knowing up front

Things that cost hours during the first bringup — documented so you don't repeat them:

- **Plymouth deadlock on long-uptime hosts.** If `systemctl is-system-running` reports `starting` and the NemoClaw installer hangs on `systemctl enable --now nvidia-cdi-refresh`, kill `/usr/bin/plymouth --wait` (`sudo kill <pid>`) and run `sudo systemctl start multi-user.target`. See `runlog/RUNLOG-2026-06-17-bringup.md` for the diagnosis.

- **Sudo across separate terminals.** Ubuntu's default `tty_tickets` scopes sudo per-TTY. `bringup/helpers/fix-sudo-tty.sh` disables that for your user so `sudo -v` in one shell is visible to all. Idempotent.

- **DGX-Spark express install.** Skipped via `NEMOCLAW_NO_EXPRESS=1` in `10-install-nemoclaw.sh`. Without that flag, the installer auto-pulls Ollama + Qwen 3.6 35B on top of your existing vLLM. Don't.

- **Hermes' OAuth setup.py hangs on multi-account Safari.** Use `gog` instead. See `30-google-oauth.md` — that's the long story short.

- **OpenShell network policy denies inference paths.** Hermes' LiteLLM router emits `/chat/completions` (no `/v1/`); the default policy only allows `/v1/...`. `50-openshell-policies/managed-inference-widen.yaml` widens the paths. (Even with that, the in-sandbox enforcer in 0.0.44 ignores the live update — that's why we pivoted to vLLM-via-`local-inference` instead of Argo-via-`managed_inference`. See the runlog.)

- **OpenShell containment is weaker than the marketing.** The default policy doesn't deny-by-default on general egress — sandboxes can reach arbitrary internet hosts, Tailscale, LAN. See `../ops/tighten-network-policy.md` for the iptables-based fix.
