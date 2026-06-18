# Platform & Architecture Options for the Spark Agent System

**Date:** 2026-06-16
**Question:** Is OpenClaw still the best base for what you're doing (sandboxed, always-on personal/conference agents with a clean script-vs-LLM split, runbooks, and real safeguards), or should you redesign — possibly on a different platform? Below: a survey of viable options with trade-offs, then a recommendation.

All product facts below were researched on 2026-06-16 (sources at the bottom). Confidence notes are included because two of the most relevant options (NVIDIA OpenShell / NemoClaw) are very new.

---

## The single most important finding

While you were hand-building containment (iptables `DOCKER-USER` DROP rules, a Docker sandbox, read-only credential mounts, the 8-layer model in `docs/CONTAINMENT.md`, the `PAUSE.*` kill switch, the append-only audit log), **NVIDIA shipped a reference stack that does almost exactly this — and validated it on the DGX Spark, your exact hardware:**

- **NVIDIA OpenShell** — "the safe, private runtime for autonomous AI agents." Enforces network / filesystem / syscall isolation, manages credentials *outside* the sandbox, proxies network/API calls, and offers **real-time, per-request policy approval** (the agent tries to reach a host, OpenShell blocks it, you approve once for the session or add a permanent policy). Apache-2.0. Currently young (docs at v0.0.5, very active).
- **NVIDIA NemoClaw** — an orchestration/lifecycle layer *on top of* OpenShell: guided onboarding, image hardening, model routing, state, observability, and **snapshots that capture skills, memories, sessions, and scheduled cron jobs**. Its tagline is literally "Run agents like **Hermes and OpenClaw** more securely inside NVIDIA OpenShell." Apache-2.0.
- Crucially, **NemoClaw runs OpenClaw *or* Hermes as the agent framework inside the sandbox** — so adopting it is not necessarily a rip-and-replace of OpenClaw; it can be a containment/ops upgrade that lets you delete most of your custom security plumbing.

This reframes your decision. The question isn't only "OpenClaw vs alternative framework." It's also "keep hand-rolling the sandbox/containment, or hand it to OpenShell."

---

## The options

| # | Option | What you keep / change | Effort to migrate | Containment & safeguards | Script-vs-LLM + cron/runbooks fit | Maturity / risk | Best if… |
|---|--------|------------------------|-------------------|--------------------------|-----------------------------------|-----------------|----------|
| **1** | **Upgrade OpenClaw in place (4.2 → 6.8), keep your custom stack** | Everything stays; you just take the 23-release jump per `UPGRADE-2026.6.8.md` | **Low** (1 maintenance window) | Your hand-rolled 8 layers, unchanged. You now *also* have native untrusted wrappers, policy plugin, exec-approvals-fail-closed sitting unused | Unchanged — your `check-todos.sh` + CALENDAR/TODO + runbooks keep working | **Low risk, high known-breakage** (Slack plugin externalized, fail-closed config, sandbox shard migration) | You want minimal change now and to defer redesign |
| **2** | **OpenClaw 6.8 + adopt native features, slim the custom layer ("SparkClaw done right")** | Keep OpenClaw + your agents; *retire* hand-rolled layers that 6.x now does natively (untrusted content wrappers, exec approvals, config-write allowlist, possibly Workboard/Task Brain in place of some TODO/CALENDAR scaffolding) | **Medium** | Mix: native OpenClaw governance + your iptables/sandbox at the host | Strong — this is your current model, simplified | Low–medium; you own the dedup of custom vs native | You like OpenClaw, want less code to maintain, but aren't ready to add NVIDIA's runtime |
| **3** | **NemoClaw + OpenShell, running OpenClaw inside** ⭐ | Keep OpenClaw + your agent definitions and runbooks; **delete most of Layers 6–8** (iptables, sandbox wiring, audit plumbing, much of the kill-switch) and let OpenShell + NemoClaw own containment, credentials, snapshots, observability | **Medium** | **Strongest out-of-the-box**, hardware-enforced, NVIDIA-maintained; real-time approval replaces your allowlist-by-convention | Strong — OpenClaw scheduling unchanged; NemoClaw snapshots even capture cron jobs | **New (v0.0.x), Apache-2.0, very active.** Bleeding edge is the risk | You want to *stop maintaining security plumbing*, stay on DGX Spark, and keep your OpenClaw mental model |
| **4** | **NemoClaw + OpenShell, running Hermes** | Replace OpenClaw with **Hermes** (Nous Research, MIT) as the agent framework, sandboxed by OpenShell. `hermesclaw` is a published, supported pairing | **High** (framework switch) | Same OpenShell containment as #3 | **Very strong** — Hermes has *native* cron (one-shot + recurring, isolated sessions, skill injection, cron-mgmt disabled inside cron to stop runaway loops = your action-budget analog) and a self-improving **skill** loop that overlaps your runbook idea | New stack on both sides | You're willing to switch frameworks to get native cron + skills + memory and shrink your scaffolding the most |
| **5** | **Hermes standalone (no OpenShell)** | New framework, self-host directly; MIT, no tracking, model-agnostic (Ollama/vLLM/Anthropic), 16+ channels incl. Slack | **High** | You re-add sandboxing/iptables yourself (back to hand-rolling) | Very strong native cron + skills + persistent memory | Framework is young (v0.2.0) but active; you own containment | You want Hermes' native features but not NVIDIA's runtime, and accept owning the sandbox |
| **6** | **Workflow-automation platform (n8n self-hosted)** | Flip the model: deterministic visual workflows first, LLM as one node; 400+ integrations, MCP nodes, AI-agent nodes, Ollama support | **High** (paradigm change) | Process-level, not agent-sandbox; you'd run it in your own container | **Excellent for the deterministic half** (your cron/scripts/pipelines become first-class), **weaker for conversational, memory-rich agents** | Mature, large community | The *valuable* part of your system is the scheduled pipelines, and the chatty-agent part is secondary |
| **7** | **Build-your-own on an agent SDK (LangGraph, or Letta for memory; NVIDIA NeMo Agent Toolkit)** | Maximum control: LangGraph = durable state machines for regulated/production workflows; Letta = best-in-class self-hosted stateful memory | **Very high** | Whatever you build; strongest *governance* ceiling, but all on you | You implement the script/LLM split and scheduling yourself (no free lunch) | Mature libraries, but you're the integrator and maintainer | You have a long-term need that justifies owning the whole stack |

> **Noted but not a fit:** **OpenHands** (ex-OpenDevin) is the SWE-bench leader for *autonomous coding agents* — wrong shape for personal-assistant / conference-ops / email-triage work. Skip it for this purpose.

---

## Recommendation

**Primary: Option 3 — move to NemoClaw + OpenShell, keep OpenClaw as the agent framework. Run a 1–2 week spike before committing.**

Reasoning, tied to your stated goals (less bloat, clearer structure, easier maintenance, strong safeguards, the script/cron-vs-LLM discipline):

1. **It deletes the code you most want to stop maintaining.** Your heaviest, most fragile, and most security-critical work — the iptables `DOCKER-USER` rules + drift detector, the Docker sandbox wiring, read-only credential mounts, the append-only audit log, and much of the `PAUSE.*` kill switch — is precisely OpenShell's job, hardware-enforced and NVIDIA-maintained. Your `docs/CONTAINMENT.md` 8-layer model collapses to roughly two: OpenShell's structural containment, plus your behavioral runbook conventions. That is the "radical clean start" you're sensing you need, without throwing away your agent designs.

2. **It's matched to your hardware and your instincts.** It's built and validated on the DGX Spark, runs local inference (Nemotron via NIM/Ollama, or your vLLM), and the real-time policy-approval flow is a cleaner, structural version of your "requires-Charlie-confirmation" allowlist — enforced by the runtime instead of by LLM goodwill.

3. **It's the lowest-conceptual-change path that still simplifies.** Keeping OpenClaw inside means your agents, runbooks, and the CALENDAR/TODO/HEARTBEAT model survive; NemoClaw even snapshots scheduled cron jobs. You get the cleanup benefit without a framework re-learn.

**Strong secondary to evaluate during the same spike: Option 4 (Hermes under OpenShell).** Hermes' *native* cron subsystem is almost identical in philosophy to what you built by hand — recurring jobs run in isolated sessions, skills injected per job, and cron-management tools disabled inside cron runs to prevent runaway loops (your action-budget concern, solved natively). Its self-improving skill loop overlaps your runbook concept. If the spike shows Hermes' cron + skills + memory would let you retire `check-todos.sh`, the runbook scaffolding, and the session-reset machinery, the larger migration may pay for itself in deleted code. `hermesclaw` proves both run under the same OpenShell, so you can A/B them on identical containment.

**What I would *not* do:** Option 1 (upgrade-and-keep-everything) only buys time — you'll carry the full custom stack into a world where the platform now does much of it, which is the exact bloat you're trying to escape. And don't start from Option 7 (build-your-own) unless the spike shows both NVIDIA stacks can't meet a hard requirement; it maximizes the maintenance burden you're trying to shed.

### The honest caveat
OpenShell and NemoClaw are **new** (v0.0.x, Apache-2.0, commits within days). For a single-operator personal/conference system that is the right risk to take *with a rollback plan*, but verify before betting on it: stand up NemoClaw on the Spark beside the current stack, run one agent (LuoJi) inside it for a week, confirm OpenShell's policy approvals + credential proxy actually cover your Slack/Google/MCP paths, and confirm vLLM-as-fallback still works through OpenShell's network policy. Keep the current 4.2 stack running until the spike passes. If NVIDIA's stack proves too raw, **fall back to Option 2** (OpenClaw 6.8, slimmed) — which is a real improvement on its own and a natural stepping stone.

### Suggested sequence
1. Do the `UPGRADE-2026.6.8.md` upgrade anyway (you need a healthy 6.8 baseline, and #2/#3 both build on it).
2. Spike NemoClaw + OpenShell on the Spark with **one** agent inside (OpenClaw first — least change).
3. In parallel, prototype the **same** agent as Hermes-under-OpenShell to see how much scaffolding Hermes' native cron/skills lets you delete.
4. Decide #3 vs #4 from evidence, then migrate agents one at a time. Keep `spark-ai-agents` as the live private repo that *consumes* whichever base you pick (don't archive it — the SparkClaw review already flagged that contradiction).

---

## Sources
- [NVIDIA: Build a Secure, Always-On Local AI Agent with NemoClaw and OpenClaw](https://developer.nvidia.com/blog/build-a-secure-always-on-local-ai-agent-with-nvidia-nemoclaw-and-openclaw/)
- [NVIDIA: Run Autonomous, Self-Evolving Agents More Safely with NVIDIA OpenShell](https://developer.nvidia.com/blog/run-autonomous-self-evolving-agents-more-safely-with-nvidia-openshell/)
- [NVIDIA: Deploy Self-Evolving Agents with a Hermes Agent and NVIDIA NemoClaw](https://developer.nvidia.com/blog/deploy-self-evolving-agents-for-faster-more-secure-research-with-a-hermes-agent-and-nvidia-nemoclaw/)
- [GitHub: NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) · [GitHub: NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) · [NemoClaw docs](https://docs.nvidia.com/nemoclaw/latest/index.html)
- [GitHub: TheAiSingularity/hermesclaw (Hermes under OpenShell)](https://github.com/TheAiSingularity/hermesclaw)
- [Better Stack: NVIDIA NemoClaw — a security layer for autonomous AI agents](https://betterstack.com/community/guides/ai/nvidia-nemoclaw/)
- [OpenClaw docs](https://docs.openclaw.ai/) · [OpenClaw 2026.6.6 release notes](https://github.com/openclaw/openclaw/releases/tag/v2026.6.6) · [OpenClaw changelog overview](https://www.remoteopenclaw.com/blog/openclaw-changelog)
- [Hermes Agent — Cron internals](https://hermes-agent.nousresearch.com/docs/developer-guide/cron-internals) · [Hermes cron scheduling](https://nousresearch-hermes-agent.mintlify.app/user-guide/features/cron) · [Hermes features overview](https://hermes-agent.nousresearch.com/docs/user-guide/features/overview)
- [Hermes Agent (Nous Research) overview](https://www.aibuilderclub.com/blog/hermes-nous-research-self-improving-agent)
- [Firecrawl: Best open-source frameworks for building AI agents in 2026](https://www.firecrawl.dev/blog/best-open-source-agent-frameworks)
- [Atlan: Best AI Agent Memory Frameworks 2026 (Letta/LangGraph/etc.)](https://atlan.com/know/best-ai-agent-memory-frameworks-2026/)
- [Vellum: Best n8n alternatives 2026](https://www.vellum.ai/blog/best-n8n-alternatives)
