# cecat/luoji migration — checkpoint 4: BLOCKED on the upstream version, not on design

**Written 2026-08-21. Supersedes `HANDOFF-2026-08-20b-cecat-migration.md`** for the
*decision*; 20b remains valid for the *design work* (see "What is still good").

Nothing has been migrated. Nothing was onboarded. Gandalf is untouched and healthy.

---

## The decision

**Do NOT onboard cecat (or luoji) onto NemoClaw `v0.0.55`.**

The migration design is sound and the goal is right. The mechanism that makes it
*safe* — one OpenShell gateway per agent, giving each its own inference route and
its own registry — was implemented upstream in July 2026, **after** our pinned
`v0.0.55` and **before** `v0.0.110`. It therefore sits inside the version range the
GB10 DMI bug currently blocks.

Interim posture: **Gandalf stays on NemoClaw; cecat and luoji stay on the existing
OpenClaw stack.** Revisit the moment the upstream DMI fix lands.

---

## Why: `v0.0.55` shares state across every sandbox

NemoClaw pins every sandbox it creates to a single OpenShell control plane named
`nemoclaw` (`src/lib/state/gateway.ts:11`), and `onboard.ts` forcibly re-stamps
`process.env.OPENSHELL_GATEWAY = GATEWAY_NAME` at ~11 sites — so that env var
cannot override it. Two consequences, both verified in source and both confirmed
as real upstream bugs:

1. **Inference is control-plane-global.** `openshell inference set` is, in its own
   help text, "Set **gateway-level** inference provider and model"; its only
   scoping flag is `--gateway`, and there is one gateway. Onboarding writes this
   route (`onboard.ts:5273`). Gandalf's config points at
   `base_url: https://inference.local/v1` — a virtual host with no DNS entry in his
   sandbox, intercepted by the L7 proxy and resolved via that shared route. So a
   second onboard silently re-points Gandalf's inference, while the per-sandbox
   registry still claims he is on `vllm-local`. Upstream:
   [#6315](https://github.com/NVIDIA/NemoClaw/issues/6315), fixed by
   [PR #6338](https://github.com/NVIDIA/NemoClaw/pull/6338) (2026-07-07). **Not in v0.0.55.**

2. **A gateway hiccup wipes the whole registry.** If the gateway image version does
   not match the installed openshell, onboard prints "Recreating..." and calls
   `destroyGateway` → `clearAll()` → `{sandboxes:{}, defaultSandbox:null}`
   (`onboard/machine/handlers/gateway.ts:151-163`, `state/registry.ts:288`). That is
   every sandbox's entry, policies, and credential hashes — no confirmation prompt.
   Same path fires if the gateway is merely unresponsive on 8080 mid-run. Related
   upstream: [#8420](https://github.com/NVIDIA/NemoClaw/issues/8420).

---

## The fix exists upstream — and we have only half of it

The single-gateway singleton was filed as
[#3053](https://github.com/NVIDIA/NemoClaw/issues/3053) ("Support multiple
NemoClaw-managed instances on a single host") and closed 2026-07-15 by
[PR #6711](https://github.com/NVIDIA/NemoClaw/pull/6711). Upstream now treats
multi-gateway as first-class: CI test
`test/e2e/live/concurrent-gateway-ports.test.ts` onboards two sandboxes on ports
8080 and 18080 and asserts mutual non-interference. Co-hosting Hermes and OpenClaw
on one host is explicitly documented as supported (distinct sandbox names required).

**The override is `NEMOCLAW_GATEWAY_PORT`, not `OPENSHELL_GATEWAY`.** Setting a
non-default port yields gateway `nemoclaw-<port>` *and* a segregated state root
`~/.nemoclaw/gateways/<port>/` with its own `sandboxes.json`, snapshots, and
credentials.

What `v0.0.55` actually has — verified directly, this is the crux:

| Piece | v0.0.55 | Introduced by |
|---|---|---|
| `NEMOCLAW_GATEWAY_PORT` env var | ✅ present (`src/lib/core/ports.ts:120`) | pre-existing |
| Per-port state root `~/.nemoclaw/gateways/<port>/` | ❌ **absent** (zero matches) | PR #6711 |
| Registry path | ❌ **hardcoded** `~/.nemoclaw/sandboxes.json` (`state/registry.ts:54`) | PR #6711 |
| Inference-route clobber guard | ❌ absent | PR #6338 |

So on `v0.0.55` you can move the *port* while both instances still share one
registry and one unguarded inference route — **the worst case: it looks isolated
and is not.** That is precisely upstream
[#4865](https://github.com/NVIDIA/NemoClaw/issues/4865) and
[#5359](https://github.com/NVIDIA/NemoClaw/issues/5359), where a second
`NEMOCLAW_GATEWAY_PORT` instance broke the first. Do not attempt this as a
workaround.

---

## This raises the priority of the upstream bug report

`docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md` is written and ready to file. Until now it
was framed as "we cannot get new features," and `HANDOFF-2026-08-20b` explicitly
called filing it *not* in the critical path.

**That framing is now wrong.** The DMI bug is what stands between us and the
supported mechanism for multi-agent consolidation. Filing it is the unblocker for
the whole cecat/luoji migration, and a concrete user-impact story ("this blocks us
from the multi-gateway support you shipped in #6711") is exactly the kind of
detail that gets a DMI-matcher patch merged quickly.

Filing remains the operator's call, but it is now on the critical path.

> **Correction to `docs/FOLLOWUPS.md`:** the line "The OpenClaw migration is NOT
> blocked by this" is **no longer accurate**. It was true in the narrow sense that
> `v0.0.55` has no N1x preflight, so `onboard` would *run*. But running it is unsafe
> for the reasons above, and the fix is upstream-only. The migration IS blocked by
> the DMI bug, transitively.

---

## What is still good (do not redo this work)

All of it is committed and none of it is invalidated — it is deferred, not wrong.

- **`HANDOFF-2026-08-20b`'s design conclusions all stand.** The gateway moves inside
  the sandbox on onboard; Slack delivery becomes native; native `openclaw cron` is
  rejected because its jobs live in `state/openclaw.sqlite`, which the OpenClaw
  manifest never declares as backed-up state; CALENDAR.md/TODO.md stay; curl beats
  httpx because the image ships no python HTTP client.
- **The runbook rewrite is done** — branch `cecat-openshell-migration` in
  `spark-ai-agents` (commit `5604f4f`, 14 files). **Not merged, deliberately.**
  Merging changes cecat's live behaviour immediately via her bind mount, and she is
  staying on the old stack for now. Leave it on the branch until the migration is
  unblocked.
- **`bringup/50-openshell-policies/cecat-egress.yaml`** — draft preset, committed.
- **The curl port** of `gmail-api.py` / `contacts-api.py` — uncommitted in
  `spark-ai-agents`, still unvalidated against the L7 proxy (only testable from
  inside a real sandbox, so it stays unvalidated until the migration happens).

## Artifacts from this session

- **Gandalf backup, verified:** `~/gandalf-backup-20260821T025800Z` (1.8 GB,
  state.db integrity-checked, zero failures). Made with `ops/backup-sandbox.sh` —
  NOT `ops/snapshot.sh`, which is fake.
- **Registry backup:** `~/nemoclaw-sandboxes.json.bak-20260821T030645Z`. A plain
  file copy is a complete restore for the registry-wipe failure mode.
- **Inference route recorded:** `~/inference-route-before-cecat.txt` —
  `vllm-local / claudeopus47 / v10`. This is Gandalf's live route; if it ever
  differs, something re-pointed it.

## Landmines (unchanged, still current)

- **Never restart vLLM or argo-shim** — argo-shim needs interactive Duo approval.
- **`ops/snapshot.sh` is fake** (no exit-code check). Use `ops/backup-sandbox.sh`.
- **`nemohermes gandalf doctor` always exits non-zero** on this host.
- **`ops/status.sh` reports a false `Inference: FAIL`** — its probe POSTs to
  `:8642/v1/chat/completions` with no auth header. Pre-existing, unrelated.
- **Gandalf's port-8642 forward can die silently** while every in-sandbox signal
  stays green. Repair: `openshell forward stop 8642 gandalf` then
  `openshell forward start -d 8642 gandalf`.
- **Do not patch NVIDIA's source** for the DMI bug — considered and rejected; it
  flips the machine's platform identity and needs re-validating every release.
- **Luoji is male** (Three Body Problem). Use "he".

## Next steps, in order

1. **File the upstream DMI bug** (operator). Now the critical path — see above.
2. **Wait for a release whose preflight matches GB10 DMI strings.** Re-test trigger
   is unchanged; it now also needs to be ≥ the release containing PRs #6338 + #6711.
3. **On upgrade, re-verify** that `~/.nemoclaw/gateways/<port>/` segregation is
   present before onboarding anything.
4. **Then resume `HANDOFF-2026-08-20b` Step 3** — onboard cecat with a distinct
   `NEMOCLAW_GATEWAY_PORT`, merge `cecat-openshell-migration`, upload CHANNELS.md,
   set the workspace config key, add the `openclaw cron --command` tick, and test
   the curl port + native Slack on her first real exec.
5. **luoji strictly after cecat is fully working.**

## Working agreement

Verify against the running system rather than inferring. Two corrections from the
operator drove this checkpoint and both were right: "gateway" was being used
ambiguously across three distinct layers (agent runtime / OpenShell control plane /
NemoClaw's pinned instance), and the assumption that NemoClaw cannot do multi-agent
was wrong — it can, just not in our version. When a finding contradicts the
project's goal, check whether it is a design limit or a version limit before
recommending a change of course.
