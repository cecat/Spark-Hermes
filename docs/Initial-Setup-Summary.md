# Initial Setup Summary

A snapshot of what was built during the initial bring-up of Gandalf, the
always-on personal-assistant agent running on the DGX Spark.

## Overview

We brought up Gandalf — an always-on personal-assistant agent — on the DGX
Spark using NVIDIA's NemoClaw + OpenShell + Hermes Agent stack, with
inference routed through Argonne Argo (Claude Opus 4.7). Along the way we
replaced a fragile dual-code-path outbox with a single sandbox-side
pipeline, layered three independent safety nets (OpenShell egress policy,
NextDNS DNS filtering, host firewall + Tailnet ingress), and built
operational scaffolding (declarative config, post-rebuild restore,
heartbeat) so the whole thing survives reboots and rebuilds without
manual fixup.

## What's in place

- **Sandboxed agent**: Gandalf runs as Hermes Agent inside an NVIDIA
  OpenShell sandbox managed by NemoClaw, with restart-policy
  `unless-stopped` so it survives host reboots and Docker daemon restarts.
- **Remote inference**: routed via LiteLLM proxy →
  [argo-shim](https://github.com/n-getty/argo-shim) (an
  Anthropic-Messages-API-shape local proxy that tunnels to Argonne's
  internal Argo gateway) → Argonne Argo (Claude Opus 4.7), with vLLM
  Qwen as a local fallback — same model family the OpenClaw agents use,
  no vendor lock-in to local-only models.
- **Slack DM as the operator surface**: Charlie talks to Gandalf in a DM;
  all reports, drafts, and alerts arrive there with ✅/❌ reactions as the
  human-in-the-loop control.
- **Email pipeline with approval gate**: inbox-triage cron drafts replies →
  outbox-processor posts them to Slack for review → sandbox-side
  outbox-send delivers via Gmail only after ✅. No mail goes out without
  explicit approval.
- **One code path for Google APIs**: the brittle "host script docker-execs
  into sandbox" path was rewritten as a Hermes `--no-agent` cron job, with
  the correct httplib2/CA-cert env vars and a one-time token-expiry shape
  normalizer, eliminating an entire class of silent failures.
- **OpenShell egress policy (layer 1)**: explicit allowlist per host
  (Google APIs, Slack, GitHub, Hugging Face, plus a curated web-readonly
  preset for news/reference/research/Eventbrite). OPA engine denies
  anything else by default.
- **NextDNS filtering (layer 2)**: every DNS query on the Spark host
  (sandbox + OpenClaw agents + host shells) goes through profile "Spark"
  with malware/phishing/porn/gambling/piracy categories blocked at the
  resolver — a second guard underneath OpenShell.
- **Tailnet-restricted ingress**: web UI, gateway endpoints, and OpenShell
  broker bound to the Spark's Tailnet IP, so they're only reachable from
  your own devices.
- **Declarative ops**: `~/.hermes/config.yaml` defines cron jobs, Google
  scopes, Slack identity; `ops/apply-cron.sh` reconciles state;
  `ops/post-rebuild.sh` restores the Google pylibs, OAuth token, OpenShell
  presets, and sandbox scripts that `nemohermes rebuild` silently drops.
- **Self-monitoring**: 15-min heartbeat script checks
  gateway/token/disk/scheduler liveness (silent on success, one Slack line
  per failure), and writes a timestamp to
  `/sandbox/.hermes/state/heartbeat-last.json` for future
  dead-mans-switch alerting if heartbeats stop entirely.

## Not yet built (named for the future)

- **Form-submission outbox**: shape mirrors email outbox (draft →
  human ✅/❌ → submit). Deferred until there's a concrete form to fill
  so the design fits a real target rather than a hypothetical one.
- **Dead-mans-switch watcher**: the heartbeat writes a timestamp every
  15 min; nothing yet reads that file to alert when it goes stale.
  The data source is in place, the alarm is not.
