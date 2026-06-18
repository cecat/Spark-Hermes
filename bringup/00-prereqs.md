# 00 — Prerequisites

Make sure these are true before starting the install. The numbered scripts assume them.

## Hardware / OS
- **NVIDIA DGX Spark** (or any NVIDIA GB10-class host)
- **Ubuntu 24.04** with kernel 6.17+
- **Docker 28+** with the user in the `docker` group (`id -nG | tr ' ' '\n' | grep docker`)
- **NVIDIA driver** working (`nvidia-smi` reports the GPU)
- **sudo** access for the install user (no need for root login)
- **~25 GB free disk** for NemoClaw + sandbox image + Node 22 + nvm cache

## Existing services this stack uses but does not install
- **vLLM container** running Qwen3-Coder-Next-FP8 (or any OpenAI-compatible model server) on `172.18.0.2:8000` on a Docker bridge named `nim_net`. This repo's `40-vllm-bridge/` units assume that exact IP and port — adjust if yours differ.

## Accounts you'll need
- **Google account** for the agent (recommend dedicated, e.g. `your-agent@gmail.com`, not your personal account). You'll create a Google Cloud project and OAuth client under it.
- **Slack workspace** where the agent will live. You'll create a new Slack app from `20-slack-app/manifest.yaml`.
- (Optional) Argo / Argonne LCRC API access if you intend to use the Argo shim path. Not required for vLLM-only.

## Tools the bringup uses
- **`gog`** CLI (the Google OAuth helper from `github.com/ditto-assistant/gog`). Install per its README before step `30-google-oauth.md`. The OpenClaw tutorial section "GOG Integration" walks through `~/.config/gogcli/` setup; mirror it here.

## What this stack does NOT need
- No system-level Python venv for Hermes (everything's in the sandbox image).
- No Tailscale (the sandbox doesn't expose anything on Tailscale; you reach the agent's API on localhost:8642).
- No GitHub Copilot, Claude API, or other paid LLM keys for inference (local vLLM is the default).

## Sanity check before proceeding

```
head -n2 /etc/os-release      # Ubuntu 24.04
nvidia-smi | head -10         # GB10 reported
docker info --format '{{.ServerVersion}}'  # 28+
docker ps --format '{{.Names}}' | grep vllm  # the vLLM container is up
```

If all four pass, run `bash 10-install-nemoclaw.sh`.
