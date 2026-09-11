# FINDING 2026-09-05 — Can Gandalf's plane and the OpenClaw planes run the same NemoClaw/OpenShell version?

Investigation only. Nothing was changed, restarted, or upgraded.

## ANSWER

**YES-WITH-WORK — but you almost certainly should not do it, and the premise of
the question is partly wrong.**

Nothing in the software prevents one version across all three planes. NVIDIA
documents multi-gateway-per-host as a supported configuration, and per-port
state segregation (`~/.nemoclaw/gateways/<port>/`) is a deliberate v0.0.108
feature that already works here. Converging Gandalf onto v0.0.108/0.0.101 costs
one sandbox rebuild plus `ops/post-rebuild.sh`; converging the OpenClaw planes
down onto v0.0.55/0.0.44 is the genuinely blocked direction, because v0.0.55
pins OpenClaw `2026.5.22` (vs `2026.7.1` in use) and lacks `--host-mount`.

But the framing "two versions means not a shared substrate" does not survive
contact with the evidence. The **gateway database schema is byte-identical
across 0.0.44 and 0.0.101** — all three planes are at the same four sqlx
migrations. What actually bites is not version skew between the planes; it is a
**bug in the v0.0.108 drift preflight that reads a hardcoded, non-port-scoped
state directory** and therefore inspects *Gandalf's* gateway when you run a
command aimed at :8090/:8091. That single defect, not the version split, is what
blocks `share mount`.

## WHY GANDALF IS ON v0.0.55

**There IS a stated reason, and it is a deliberate decision — not drift.**

`Spark-Hermes/docs/FOLLOWUPS.md:154-178`, verbatim:

> ## Platform upgrade — RESOLVED 2026-08-21: don't upgrade, run two control planes
>
> **cecat is live under NemoClaw/OpenShell alongside Gandalf. Nothing was upgraded.**
>
> The week of "upgrade, then migrate" was solving the wrong problem. The goal was
> never to upgrade Gandalf — it was to run a second agent. Those are independent,
> because OpenShell supports **multiple control planes on one host**.

and at `:177-178`:

> **Gandalf was never upgraded, rebuilt, or restarted.**

Reinforced in `ops/nmc.sh:11` — "`nemoclaw` on PATH is v0.0.55 (Gandalf's,
**deliberately frozen**)" — and recorded as a status label in
`docs/HANDOFF-2026-09-01-migration-status.md:49` (`gandalf | :8080 (FROZEN
v0.0.55)`).

The upgrade was planned in detail
(`DGX-Spark/docs/PLAN-2026-08-19-upgrade-then-migrate.md`, phases P0–P5) and
**abandoned on purpose** on 2026-08-21 once multi-plane was discovered. P1
failed preflight first, for a reason worth keeping
(`PLAN-2026-08-19-upgrade-then-migrate.md:262-286`, §2g.2): the v0.0.110
admission check gates on **process identity (argv0)**, not version. Gandalf's
gateway runs as bare `/home/catlett/.local/bin/openshell-gateway` with no tag
and no flags, so it can never be recognised — versus the OpenClaw gateways which
run tagged as `openshell-gateway[nemoclaw=nemoclaw-8090;port=8090]`. **Verified
live**: `ps -eo pid,args` shows exactly that split.

Important distinction the record supports: the decision was *"we don't need to
upgrade him"*, **not** *"he can't be upgraded"* and **not** *"he depends on
0.0.44"*. No document anywhere claims Gandalf-specific state requires 0.0.44. I
searched `Spark-Hermes/{docs,runlog,bringup}`, `DGX-Spark/{docs,runlog}`,
`spark-ai/`, `spark-fabric/`, `OpenClaw-Tutorial/`, `gandalf-bringup/`.

## CONVERGENCE OPTIONS

| Option | What it requires | What breaks | Reversible? |
|---|---|---|---|
| **Move Gandalf up to v0.0.108 / 0.0.101** | Sandbox rebuild (destroys + recreates container; no bind mounts, so the writable layer is the state). Snapshot first, then `ops/post-rebuild.sh` to re-inject `platforms.*`, certifi CA, `google-api-python-client`, `EXTRA_ENV_KEYS`, skills, memories, cron. Re-point the global npm symlink (currently `node_modules/nemoclaw -> gandalf-bringup/nemoclaw-src`). Swap `~/.local/bin/openshell*` to the 0.0.101 build. | Hermes inbound messaging (Slack/Telegram `platforms.*`) is wiped by rebuild unless post-rebuild re-injects it — CLAUDE.md flags this as **not yet rebuild-safe**. Hermes cron, FALDA distiller, Google OAuth all need re-verification. LiteLLM/vLLM/argo bridges are host-side and unaffected. **No DB migration risk — schemas are identical.** | Yes for binaries (0.0.44 rescued at `gandalf-bringup/openshell-0.0.44-rescued/`, SHA256SUMS present). The rebuilt container is **not** reversible except from snapshot. |
| **Move OpenClaw planes down to v0.0.55 / 0.0.44** | Rebuild cecat + luoji on the old tree. | **Blocked in practice.** v0.0.55 pins OpenClaw `2026.5.22` (`agents/openclaw/manifest.yaml:22`) vs `2026.7.1` in use — a forced agent downgrade. v0.0.55 has **no `--host-mount`** (grep: zero hits), killing the `/shared` contract outright. v0.0.55 has **no per-port state root** (`REGISTRY_FILE` is a single hardcoded `~/.nemoclaw/sandboxes.json`, `state/registry.ts:54`) and no inference-route guard, so both agents would share Gandalf's registry and inference route — cecat is `claudesonnet46`, luoji is `claudeopus47`, so one would be silently re-pointed. | Effectively no. Do not do this. |
| **Stay split** | Nothing. Already working. | Nothing today. Costs: the `share mount` preflight bug below; `nemoclaw` on PATH remains a live footgun needing the guard script; two binary sets to patch for CVEs. | N/A |

## IS COEXISTENCE SUPPORTED?

**Yes — by design, and NVIDIA documents it.** Per NVIDIA's own docs: *"If you
intentionally run separate OpenShell gateways on the same host, you should set a
different `NEMOCLAW_GATEWAY_PORT` before each onboarding run. NemoClaw isolates
the gateway name and local state by port so one port-specific gateway does not
replace another."* Non-default ports get `~/.nemoclaw/gateways/<port>/`.

Confirmed in source and on disk:
- `gateway-binding.ts:15-19` — the whole module exists to give non-default ports
  a `-<port>` suffixed name/dir/container "so two sandboxes on distinct gateway
  ports never collide."
- On disk: `~/.nemoclaw/gateways/{8090,8091}/` and
  `~/.local/state/nemoclaw/openshell-docker-gateway-{8090,8091}/` all exist and
  are correctly populated. The per-port `runtime.json` files correctly record
  `"openshellVersion": "0.0.101"` and the 0.0.101 `gatewayBin`.

**Caveat — this is not fully hardened upstream.** NVIDIA/NemoClaw issue #5359
("Multi-instance NemoClaw: second gateway-port instance breaks other sandbox")
is open. The `share mount` failure below is a concrete instance of the same
class of bug.

## SHARE MOUNT — CAN IT BE SCOPED? (question F)

**YES. The sshfs path is unblocked today, with one env var.**

Root cause, read from source (I did **not** run `share mount`):

1. `share mount` → `runShareMount` → `deps.ensureLive(sandboxName)`
   (`share-command.ts:219`) → `ensureLiveSandboxOrExit`
   (`share-command-deps.ts:51-53`).
2. That calls `detectOpenShellStateRpcPreflightIssue`
   (`gateway-state.ts:196,257`) → `getGatewayHostProcessDrift`
   (`gateway-drift.ts:405`).
3. Drift compares `getInstalledOpenshellVersionOrNull()` — 0.0.101 from PATH —
   against `getHostProcessGatewayRuntimeOrNull()` (`:385-398`).
4. **The bug:** that reads the marker at
   `resolveDockerDriverGatewayStateDir()`, which is **hardcoded** to
   `~/.local/state/nemoclaw/openshell-docker-gateway` —
   `host-gateway-process.ts:122-129`, with **no port suffix**. The port-aware
   `resolveGatewayStateDirName(port)` exists at `gateway-binding.ts:165` but
   `gateway-drift.ts` never imports it (confirmed: its import list has no
   `gateway-binding`).
5. So the preflight reads **Gandalf's** marker: `pid 52123`, `gatewayBin
   ~/.local/bin/openshell-gateway`, `openshellVersion 0.0.44`. PID 52123 is
   **alive** (verified), so `isLiveGatewayProcess` returns true and that binary
   is accepted. It re-probes `--version` → `0.0.44` ≠ `0.0.101` → drift →
   fail-closed with exactly the reported message
   (`gateway-drift.ts:546,555-557`): *"Running gateway binary: … (0.0.44)"* vs
   *"Installed OpenShell: 0.0.101"*.

The comparison is Gandalf's binary against luoji's CLI — **the two planes were
never actually compared.**

The fix is the documented production escape hatch. `resolveDockerDriverGatewayStateDir`
honours `NEMOCLAW_OPENSHELL_GATEWAY_STATE_DIR` **first** (`:126-127`), and that
var is **not** test-gated (unlike `NEMOCLAW_DISABLE_GATEWAY_DRIFT_PREFLIGHT`,
which requires `VITEST`/`NODE_ENV=test` — `gateway-drift.ts:126-133`). Pointing
it at the correct per-port dir makes the preflight read the marker that already
says `0.0.101`, so it compares 0.0.101 against 0.0.101 and passes honestly —
this **preserves** the safety check rather than disabling it.

Exact invocation for luoji (:8091):

    NEMOCLAW_OPENSHELL_GATEWAY_STATE_DIR="$HOME/.local/state/nemoclaw/openshell-docker-gateway-8091" \
      bash ops/nmc.sh luoji share mount

For cecat, substitute `-8090` and `cecat`.

**One caveat, stated honestly:** the per-port markers record **dead PIDs**
(8090 → 3593861, 8091 → 2776928; both `DEAD`, while the real gateways are 2821318
and 4165853 — the markers predate later restarts). With a stale marker,
`resolveHostProcessGatewayBin` falls through to its candidate list
(`gateway-drift.ts:349-358`), which begins with `dirname(resolveOpenshell())` —
and since `ops/nmc.sh:62` puts the 0.0.101 bin dir first on PATH, that still
resolves to the 0.0.101 gateway binary. So it should pass either way. If it does
not, add `NEMOCLAW_OPENSHELL_GATEWAY_BIN="$HOME/gandalf-bringup/openshell-0.0.101/bin/openshell-gateway"`,
which is checked immediately after the marker (`:349-350`) and is the same
mechanism already used in `DGX-Spark/runlog/2026-08-20-p1-0-rehearsal-gateway-up.md:28`.

## VERSION DISCREPANCY

**Resolved: v0.0.108 is what is installed and used. The plan's "v0.0.110" is
stale text.**

All three trees are real git checkouts:

| Path | `git describe` | Role |
|---|---|---|
| `nemoclaw-src` | **v0.0.55** | Gandalf. Symlinked as the global npm module. |
| `nemoclaw-src-v0.0.108` | **v0.0.108** | cecat + luoji, via sidecar. |
| `nemoclaw-src-v0.0.110` | tag `latest` = **v0.0.110** | Downloaded 2026-08-19 during the abandoned plan. **Unused.** |

`ops/nmc.sh:34` and both `ops/{cecat,luoji}-env.sh` point exclusively at
`nemoclaw-src-v0.0.108/dist/nemoclaw.js`. The v0.0.110 tree is a leftover
artifact of the plan written before the N1x gate was bisected to v0.0.109 — it is
the version that *cannot* run here. The blueprint pin table in the task is still
correct, because v0.0.108 and v0.0.110 both pin OpenShell `0.0.101` (min==max,
verified in both `nemoclaw-blueprint/blueprint.yaml:6-7`).

Also worth recording: `/proc/52123/exe` reports **`(deleted)`** — Gandalf's
running gateway is an unlinked inode. The file at `~/.local/bin/openshell-gateway`
was replaced on 2026-08-20 (same size, 29923528 bytes, matching the rescued
0.0.44). The running process is byte-identical 0.0.44, so this is benign today,
**but Gandalf's gateway cannot be restarted-in-place from a file that the running
process no longer references.** It is fine because the on-disk 0.0.44 is correct.

## RECOMMENDATION

**Stay split, fix the `share mount` preflight scoping today, and revise
`GOALS.md` to say "common substrate" means the *stack components*, not identical
version numbers.**

The GOALS.md premise is not as broken as it looks. All three planes run the same
NemoClaw software, the same OpenShell architecture, the same container runtime,
the same gateway DB schema, and the same host substrate. Version skew between
two exact-pinned releases of the same product is version skew, not two
substrates — and NVIDIA explicitly supports per-port isolation, which is the
mechanism that made three concurrent agents possible at all.

Converging *up* is achievable but buys little and risks the one agent whose
scheduled work demonstrably runs, through a rebuild path that CLAUDE.md itself
says is not yet rebuild-safe for inbound messaging. Converging *down* is
blocked by the OpenClaw agent pin and the loss of `--host-mount`.

Do this instead, in order:
1. Unblock sshfs now with the `NEMOCLAW_OPENSHELL_GATEWAY_STATE_DIR` invocation above.
2. Fold that var into `ops/nmc.sh` and `ops/{cecat,luoji}-env.sh` so every
   secondary-plane command is correctly scoped — this closes a whole class of
   "the tool inspected Gandalf instead" bugs, not just `share mount`.
3. File the upstream bug: `getGatewayHostProcessDrift` should use
   `resolveGatewayStateDirName(GATEWAY_PORT)`. It is a one-line fix in NVIDIA's
   tree and plausibly the same root cause as open issue #5359.
4. Revise GOALS.md. Add a line stating that per-plane version pinning is
   intentional and that convergence is deferred until Gandalf needs a rebuild
   for an independent reason — at which point he lands on v0.0.108 for free.

## CONFIDENCE

**Verified by running a command (highest confidence):**
- `openshell --version` / `openshell-gateway --version` / `openshell-sandbox --version` → all `0.0.44`.
- `git describe --tags` in all three nemoclaw trees → v0.0.55, v0.0.108, v0.0.110.
- `ps -eo pid,lstart,args` → three gateways; Gandalf's untagged, the other two tagged.
- `readlink /proc/<pid>/exe` → Gandalf's is `(deleted)`; :8090/:8091 both run the 0.0.101 binary.
- `kill -0` liveness → 52123 alive; per-port marker PIDs 3593861 / 2776928 both dead.
- `cat runtime.json` in all three state dirs → 0.0.44 vs 0.0.101 as described.
- Read-only `sqlite3` on all three `openshell.db` → identical 4-row `_sqlx_migrations`.
- `ls ~/.nemoclaw/gateways/` → per-port roots exist.

**Read in source (high confidence, statically traced, not executed):**
- The entire `share mount` → `ensureLive` → drift → hardcoded-state-dir chain, with file:line above.
- `NEMOCLAW_OPENSHELL_GATEWAY_STATE_DIR` is honoured in production and is not test-gated.
- v0.0.55 lacks `--host-mount` and per-port state; pins OpenClaw `2026.5.22`.

**Read in project docs (medium — quotes verified verbatim against the files):**
- The FOLLOWUPS.md decision and the §2g argv0 analysis. I re-read both directly
  rather than relying on the search agent's summary.

**Corrected during this investigation:** a preliminary search reported "57
one-way SQLite migrations" between 0.0.44 and 0.0.101. **That is wrong** — I
read all three databases and they carry the identical four migrations. Do not
let that claim propagate into planning; it materially overstates upgrade risk.

**Inferred (flagged as such):** that the stale per-port marker PIDs will still
resolve to the right binary via PATH fallback. Traced statically; not executed,
because executing it means running `share mount`, which was prohibited.

## DENIED

None. No command was blocked or refused during this investigation.

## Prohibitions observed

No upgrades, binary swaps, restarts, config edits, or mounts. No bare `nemoclaw`
invoked in any form. No operation on Gandalf's :8080 plane — read-only
inspection only. `share mount` was **not** run; question F is answered from
source. No tokens or Slack IDs printed.
