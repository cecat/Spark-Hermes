# Bring-up Plan: NemoClaw + OpenShell + Hermes — Agent "Gandalf"

**Target executor:** Claude Code running on the DGX Spark (`spark-ts`).
**Goal:** Stand up one always-on agent named **Gandalf** (`gandalf`) — taking over the overseer/guardian duties previously held by LuoJi — running as **Hermes** inside an **NVIDIA OpenShell** sandbox managed by **NemoClaw**, with **Slack**, **Gmail**, and **Google Drive** access, a **cloud-or-Argo primary model with local vLLM fallback**, and native **cron** scheduling.
**Date written:** 2026-06-16.

---

## 0. How to run this plan (read first)

This plan is written so it can run **unattended after kickoff**, provided the human supplies the credentials in §1 *before* saying "go." Everything that requires a human (creating a Slack app, Google OAuth consent, Duo for the Argo tunnel) is front-loaded into §1. After that, the executor proceeds through Phases A–H autonomously.

**Operating rules for the executor (Claude Code):**

1. **This stack is alpha and moves fast — do NOT trust commands from memory.** At the start of each phase, fetch the live doc(s) linked in that phase and reconcile any command/flag drift before running anything. The NemoClaw docs banner literally says "alpha software… APIs and behavior may change." If a documented command differs from this plan, **follow the docs and note the deviation** in the run log.
2. **Idempotency.** Before each install/config action, check whether it's already done. Re-running the plan must not duplicate state.
3. **Verification gates are mandatory.** Each phase ends with a ✅ PASS check. If a gate fails, **stop, write the failure to `~/gandalf-bringup/RUNLOG.md`, and do not proceed** to the next phase. Never paper over a failed gate.
4. **Run log.** Append a timestamped entry for every step (command, result, version observed) to `~/gandalf-bringup/RUNLOG.md`. Record exact versions of NemoClaw, OpenShell, and Hermes observed.
5. **Secrets discipline.** Never echo token values into the run log. Store secrets only where the docs specify (`~/.hermes/.env` at mode `600`, host-side OpenShell credential store). Confirm presence by name, not value.
6. **Non-destructive.** Do not touch the existing OpenClaw `2026.4.2` stack, its Docker volumes, or `~/code/spark-ai*`. This is a parallel build. The Argo shim and vLLM are *shared* services (read/connect only).
7. **Stop-and-ask triggers.** If a required credential from §1 is missing, or a model/endpoint fails validation, or OpenShell blocks a path you can't resolve via documented policy, stop and post a single precise request to the human (Slack DM to Charlie if Slack is up yet, otherwise write it to `RUNLOG.md` and halt).

**Working dir:** `~/gandalf-bringup/` (create it; holds RUNLOG.md, fetched docs, and scratch).

---

## 1. Kickoff inputs (human provides these BEFORE "go")

Put each item in place, then tell the executor to start. The executor will verify each is present as its first action (Phase A gate).

| # | Input | Where it goes / how to confirm | Notes |
|---|-------|--------------------------------|-------|
| 1 | **Slack bot token** `xoxb-…` and **app-level token** `xapp-…` | `~/.hermes/.env` as `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN` (mode 600) | Create the app via the Hermes-generated manifest (Phase D explains). Human must create the app + install to workspace. |
| 2 | **Your Slack Member ID** (e.g. `U01ABC2DEF3`) | `~/.hermes/.env` as `SLACK_ALLOWED_USERS` | Without this Hermes denies all messages by default (safety). |
| 3 | **Gandalf's Slack channel ID** (e.g. `#agent-gandalf`) | `~/.hermes/.env` as `SLACK_HOME_CHANNEL` | Create the channel; the bot will be invited in Phase E. |
| 4 | **Google OAuth client secret JSON** (Desktop-app type) for a GCP project with **Gmail + Drive (+ People/Docs/Sheets) APIs enabled** | Path noted for the Google Workspace skill setup (Phase F) | Reuse an existing GCP project or make a new one. **Publish the consent screen** (don't leave it in "Testing") to avoid the 7-day token death. |
| 5 | **Argo shim up** — `argo-shim` on `127.0.0.1:44497` with its Duo'd SSH tunnel live | Confirm: `curl -s http://127.0.0.1:44497/v1/models` returns models | Human completes Duo at tunnel start. Identity string is `catlett`. |
| 6 | **vLLM up** — Qwen3-Coder-Next-FP8 served on `localhost:8000` | Confirm: `curl -s http://localhost:8000/v1/models` lists the model | Shared with the existing stack; do not restart it. |
| 7 | **Model choice** — primary + fallback | Decide: primary = `argo` (claudesonnet46) **or** a cloud key; fallback = `vllm/<model-id>` | Default assumption: **primary = Argo `claudesonnet46`, fallback = local vLLM.** |

If any of 1–7 is absent at kickoff, the executor halts at the Phase A gate with a list of what's missing.

---

## Phase A — Preflight & discovery

**Do:**
1. `mkdir -p ~/gandalf-bringup && cd ~/gandalf-bringup`; start `RUNLOG.md`.
2. Verify host prereqs (record versions): `head -n2 /etc/os-release` (expect Ubuntu 24.04), `nvidia-smi` (expect GB10), `docker info --format '{{.ServerVersion}}'` (expect 28.x+), `node -v`.
3. Fetch and save the current docs (they govern the exact commands):
   - NemoClaw Quickstart + Inference Options + Network Policy + Security: `https://docs.nvidia.com/nemoclaw/latest/`
   - OpenShell: `https://github.com/NVIDIA/OpenShell`
   - **Hermes-under-OpenShell path:** NVIDIA "Deploy Self-Evolving Agents with a Hermes Agent and NemoClaw" blog + `https://github.com/TheAiSingularity/hermesclaw` + `https://github.com/NVIDIA/NemoClaw`
   - Hermes: Slack `…/messaging/slack`, Google Workspace `…/skills/google-workspace`, Cron `…/developer-guide/cron-internals`, Gateway setup `…/getting-started/quickstart`.
4. Confirm §1 inputs 5 & 6 (Argo + vLLM reachable). Confirm §1 inputs 1–4, 7 exist (token vars present in `~/.hermes/.env`; client secret file present).

**✅ GATE A:** Host meets prereqs; all §1 inputs present; all docs fetched. Else halt with the missing list.

---

## Phase B — Install NemoClaw + OpenShell

**Do (reconcile with fetched NemoClaw Quickstart first):**
1. Install per docs (current published path): `curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash` (verify this URL against the live Quickstart before running).
2. `source ~/.bashrc` so the `nemoclaw` / `openshell` CLIs resolve.
3. Confirm CLIs exist: `nemoclaw --help`, `openshell --help`. Record versions.

**✅ GATE B:** `nemoclaw` and `openshell` CLIs run and report versions logged. Else halt.

---

## Phase C — Choose topology & create the sandbox for Gandalf

NemoClaw can run **OpenClaw or Hermes** inside OpenShell. Determine the **currently supported Hermes path** from the Phase A docs and pick:

- **Topology A (preferred if turnkey):** NemoClaw-managed Hermes — use `nemoclaw onboard` selecting Hermes as the agent framework (and the inference provider from Phase D). Sandbox name: **`gandalf`**.
- **Topology B (fallback):** Create an OpenShell sandbox named `gandalf`, then install Hermes inside it manually (`pip`/install per Hermes quickstart), with Hermes config pointed at `inference.local` (the in-sandbox inference endpoint OpenShell provides).

**Do:**
1. Record which topology the docs currently support; choose accordingly; note the decision in RUNLOG.
2. Create/onboard the `gandalf` sandbox. Accept the default OpenShell **policy presets** (filesystem + network restrictions) — we tighten/approve specific endpoints in Phases D–F.
3. Capture the tokenized Web UI URL if one is produced (store in RUNLOG, not chat).

**✅ GATE C:** A sandbox named `gandalf` exists and starts; `nemoclaw gandalf status` (or the documented equivalent) reports healthy. Else halt.

---

## Phase D — Inference: Argo primary + vLLM fallback

This is the **highest-risk item** (see PLATFORM-OPTIONS doc): NemoClaw routes the agent to a single `inference.local`, while the *fallback chain* lives in the Hermes config. Verify failover actually composes.

**Do:**
1. **Primary = Argo via the shim.** Configure the inference provider as **"Other Anthropic-compatible endpoint"**: base URL `http://127.0.0.1:44497` (host-side; OpenShell forwards from the host, so the old socat `172.18.0.1` bridge is likely unnecessary — verify), model `claudesonnet46`, key/identity `catlett` (`COMPATIBLE_ANTHROPIC_API_KEY`). Confirm the auth header the provider sends is accepted by the shim (try a one-shot inference).
2. **Enable vLLM as fallback.** Set `NEMOCLAW_EXPERIMENTAL=1` so the Local vLLM option (`localhost:8000`, auto-detect model) is available. In **Hermes' `~/.hermes/config.yaml`**, set the fallback chain: `fallback_model` / `fallback_providers` → the vLLM model id (query `http://localhost:8000/v1/models` for the exact `id`).
3. **Failover test:** with Argo up, send a test prompt and confirm it answers via Argo. Then make the primary unreachable (e.g., temporarily point the primary at a dead port, or pause the shim) and send another prompt; confirm Hermes falls over to vLLM **through OpenShell's routing**.

**✅ GATE D:** A test prompt returns a real completion on the primary, AND fails over to vLLM when the primary is down. If failover does **not** compose through OpenShell, fall back to running **vLLM as primary** (fully local, the NVIDIA-default config), log the limitation, and continue.

---

## Phase E — Slack

Use the verified Hermes Slack flow (from `…/messaging/slack`).

**Do:**
1. Generate the app manifest: `hermes slack manifest --write` (writes `~/.hermes/slack-manifest.json`). *(Human created the app from this manifest at kickoff per §1; if not yet created, halt and post the manifest + instructions.)*
2. Confirm `~/.hermes/.env` has `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS`, `SLACK_HOME_CHANNEL` (file mode `600`).
3. Ensure required **scopes** (`chat:write`, `app_mentions:read`, `channels:history`, `channels:read`, `groups:history`, `im:history`, `im:read`, `im:write`, `users:read`, `files:read`, `files:write`) and **events** (`message.im`, `message.channels`, `message.groups`, `app_mention`) are present, the **Messages Tab** is on, and the app was **reinstalled** after any change. (The manifest sets these; verify.)
4. **OpenShell network policy:** approve Slack's Socket Mode egress (`slack.com` / WebSocket) for the `gandalf` sandbox via `nemoclaw gandalf policy-add` (or approve at runtime via the OpenShell TUI). Persist it.
5. Start the gateway as a service: `hermes gateway install` (or `sudo hermes gateway install --system`). Invite the bot: `/invite @Gandalf` in the home channel.

**✅ GATE E:** A DM from the allowed user gets a reply; an `@Gandalf` mention in `#agent-gandalf` gets a threaded reply; a cron/home-channel test post lands in the channel. Else halt.

---

## Phase F — Gmail + Google Drive (Google Workspace skill)

Use the Hermes **Google Workspace** skill (`skills/productivity/google-workspace/`), which covers Gmail + Drive (+ Calendar/Sheets/Docs/Contacts) via OAuth2 with auto-refresh, preferring the `gws` CLI.

**Do:**
1. Place the §1 client-secret JSON where the skill expects it (per the fetched skill doc).
2. Run the agent-driven setup (the skill is "ask Hermes to set up Google Workspace"). Since this is unattended, drive it via the documented setup script/flow: enable APIs (Gmail, Drive, People, Docs, Sheets), generate the auth URL. **The browser consent is the one genuinely interactive step** — if no valid `token.json` exists yet, halt and post the auth URL for the human to approve, then resume and paste back the redirect (or have the human pre-place a valid `token.json` at kickoff to keep it fully unattended).
3. **OpenShell network policy:** approve egress to Google API hosts (`*.googleapis.com`, `oauth2.googleapis.com`, `accounts.google.com`) for the sandbox; persist.
4. **Credential placement:** keep the OAuth token where the host/OpenShell credential model wants it. Note the refresh question from the tutorial (E-credentials / I.2): if Hermes refreshes the token itself it needs write access to the token file; if the host refreshes, mount read-only. Follow whichever the skill requires.

**✅ GATE F:** Each of these returns valid JSON (run inside the sandbox via the skill's `$GAPI`): `gmail search "is:unread" --max 3`; `drive search "report" --max 3`. A test `gmail send` to the human's own address is **optional** and only after confirming the address. Else halt.

---

## Phase G — Scheduling (native cron) + a first duty

Replace the OpenClaw `check-todos.sh`/`CALENDAR.md`/`TODO.md` scaffolding with Hermes-native cron (see cron-internals doc).

**Do:**
1. Create one **recurring** job as a smoke test, e.g. a daily 08:00 Central briefing delivered to `SLACK_HOME_CHANNEL`:
   `hermes cron create` → schedule `0 14 * * *` (08:00 CT = 14:00 UTC; confirm host TZ), deliver `slack`, prompt = a simple "good morning" summary.
2. Create one **one-shot** job (`30m` delay) to confirm the TODO-equivalent path; verify it fires once and moves to `completed`.
3. (Optional, if porting a real duty) attach a **skill** (= a runbook) and/or a **script-backed job** (Python runs before the turn, stdout injected) to mirror the runbook+script pattern.

**✅ GATE G:** `hermes cron list` shows both jobs; the one-shot fires within its window and is delivered to Slack; `last_status: ok`. Else halt.

---

## Phase H — Containment verification + handoff

**Do (verify OpenShell is actually containing, then write the report):**
1. **Network isolation holds:** from inside the sandbox, attempt egress to a *non-approved* host (e.g. `curl https://httpbin.org/get`) and confirm OpenShell **blocks** it (the approved set is only inference, Slack, Google). Log the block.
2. **Credential isolation:** confirm the Slack/Google tokens are **not readable inside the sandbox** beyond what the skill needs (OpenShell keeps provider creds host-side). Confirm the API key never entered the sandbox env.
3. **Lateral-movement check:** confirm the sandbox cannot reach the LAN / Tailscale range / SSH (the role OpenShell now plays instead of your iptables rules).
4. **Snapshot:** take a NemoClaw snapshot of `gandalf` (captures skills, memory, sessions, cron jobs) so there's a restore point.
5. Write `~/gandalf-bringup/HANDOFF.md`: versions installed, topology chosen (A/B), primary/fallback model + whether failover composed, what OpenShell policies were approved, the one interactive step(s) that required the human, and any deviations from this plan.

**✅ GATE H (done):** Gandalf answers in Slack, can read Gmail + Drive, runs a scheduled job, and OpenShell demonstrably blocks un-approved egress. Snapshot exists. HANDOFF.md written.

---

## Identity seed for Gandalf (apply during Phase C/E)

- **Name / handle:** Gandalf / `gandalf`. **Role:** takes over the overseer/guardian duties previously held by LuoJi — the watchful steward of the system (naming theme shifts from *Three-Body* to Tolkien).
- **Mandate (starter):** personal assistant on the operator's chosen Google account (typically a dedicated agent-only address such as `<agent-name>.<operator>@gmail.com`, separate from the operator's personal inbox to bound blast radius) — Slack conversation, Gmail triage, Drive review. Mirror the previous overseer agent's tone but start with **review-first** posture (no autonomous email sends until trust is established; encode "never send email without explicit approval" as a skill guardrail — this is the one E5 piece OpenShell doesn't cover for you).
- Keep his workspace/persona files minimal at first (Hermes persona + memory); grow skills as duties are confirmed.

---

## Rollback / cleanup

- Stop: `nemoclaw stop` / `nemoclaw gandalf stop` (per docs).
- Full removal: `~/.nemoclaw/source/uninstall.sh` (check flags in the live troubleshooting doc).
- Nothing in this plan modifies the existing OpenClaw 4.2 stack, so rollback is simply removing the NemoClaw sandbox; the old system is untouched.

---

## Sources
- [NemoClaw docs](https://docs.nvidia.com/nemoclaw/latest/index.html) · [Inference Options](https://docs.nvidia.com/nemoclaw/latest/inference/inference-options.html) · [NemoClaw GitHub](https://github.com/NVIDIA/NemoClaw) · [OpenShell GitHub](https://github.com/NVIDIA/OpenShell)
- [NVIDIA NemoClaw + OpenClaw walkthrough](https://developer.nvidia.com/blog/build-a-secure-always-on-local-ai-agent-with-nvidia-nemoclaw-and-openclaw/) · [hermesclaw (Hermes under OpenShell)](https://github.com/TheAiSingularity/hermesclaw)
- [Hermes Slack setup](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack) · [Google Workspace skill](https://hermes-agent.nousresearch.com/docs/user-guide/skills/google-workspace) · [Cron internals](https://hermes-agent.nousresearch.com/docs/developer-guide/cron-internals) · [Hermes GitHub](https://github.com/NousResearch/hermes-agent)
