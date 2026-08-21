> ⚠️ **SUPERSEDED 2026-08-20 — do not act on this file.**
> The live plan is `docs/HANDOFF-2026-08-20b-cecat-migration.md`.
> Steps 1 and 2 are DONE. Two premises below are now known FALSE:
> `--host-mount` does not exist on v0.0.55, so Step 2's "irreversible, get it
> wrong and the sandbox must be recreated" warning is void; and the smoke-test
> approach implied by Step 3 cannot be front-run from the host.
> Kept for provenance only — its landmines and Steps 4–6 were carried into 20b.

# Migrate OpenClaw agents (cecat, luoji) into NemoClaw/OpenShell

**Written 2026-08-20. This is the live plan — start here.** Self-contained; no
prior conversation needed. Nothing on the host has been changed yet.

---

## Context — why this plan exists

The operator asked for a plan to upgrade Hermes, OpenShell and NemoClaw to
latest. Investigation on 2026-08-20 established that **the upgrade is blocked
upstream and cannot be done**, while **the OpenClaw migration — the thing that
actually bothers him — is available today**. This plan drops the upgrade and
executes the migration.

**Goal:** get cecat and luoji off hand-rolled Docker Compose scaffolding and
into the same NemoClaw/OpenShell substrate Gandalf already runs on.

**Non-goal:** upgrading anything. See "Why the upgrade is blocked" below.

### Current state (verified 2026-08-20, nothing on the host was changed)

| Component | Version | Notes |
|---|---|---|
| NemoClaw / nemohermes | `v0.0.55` | CLIs report this; npm package says `0.1.0`. Same install. |
| OpenShell | `0.0.44` | host binaries in `~/.local/bin` |
| Hermes (Gandalf) | `v0.14.0 (2026.5.16)` | reports semver *and* calendar |
| OpenClaw (cecat, luoji) | `2026.6.11` | hand-rolled Compose, **not** in OpenShell |

Gandalf is healthy — sandbox Ready, vLLM inference OK, container up 36h.

Semver note: `v0.0.110` **is newer** than `v0.0.55`. The third segment compares
as an integer (55 → 99 → 110). v0.0.55 = 2026-05-29, v0.0.110 = 2026-08-18.

### Why the upgrade is blocked — do not re-derive this

`v0.0.110` preflight reads `/sys/class/dmi/id/product_name` =
`Dell Pro Max with GB10 FCM1253`, matches none of its NVIDIA-branded patterns,
and falls through to the N1x probe. `collectN1xIdentity`
(`src/lib/inference/platform-identity/n1x.ts:128`) sets `candidate = true`
merely because `/etc/fastos-release` **opens successfully** — before reading a
byte. That file says `NAME="DGX SPARK FASTOS"`, not the required exact
`NAME="N1x FASTOS"` → `host.platform.n1x_unqualified` → `exit(1)`.

- Gates **`rebuild`, not just `onboard`** (chain: `rebuild-pipeline` →
  `preflightAuthoritativeRebuildTarget` → `runFatalRuntimePreflight` →
  `assertOnboardHostReadiness` → hard exit).
- **No supported override.** The `allowDeferredN1xManagedVllm` waiver covers a
  different finding; path options are test-injection params, not env vars.
- **Patching NVIDIA's source was considered and REJECTED** — it flips the
  machine's platform identity (feeds GPU-route policy and GPU preflight) and
  would need re-validating on every future release.
- `v0.0.110` shipped 2026-08-18 and is still the newest remote tag → likely
  unreported.

Detail: `docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md`. Decision + loose ends:
`docs/FOLLOWUPS.md`. Also summarized in `CLAUDE.md` (gitignored, host-local).

### Why the migration is NOT blocked

`v0.0.55` has **no platform-qualification gate at all** — `src/lib/readiness/`
does not exist; zero matches for `N1x` / `fastos-release` across `src/`. Its
only DMI read (`src/lib/inference/nim.ts:157`) is for NIM inference sizing and
gates nothing. The N1x check was introduced somewhere in v0.0.56–v0.0.110.

The old plan (`~/code/DGX-Spark/docs/PLAN-2026-08-19-upgrade-then-migrate.md`)
sequenced migration *behind* the upgrade. That ordering assumed the upgrade was
achievable. **It is not, so the ordering is void.**

**Accepted cost:** onboarding onto `v0.0.55` means upgrading all agents together
later, once NVIDIA ships a fix. Some work happens twice. Chosen deliberately
over waiting on someone else's release cycle.

**Unverified — treat the first onboard as the test:** I confirmed no *gate*
stops a `v0.0.55` onboard. That is not the same as proving one succeeds
end-to-end.

---

## Landmines — read before touching anything

- **Two gateways are running.** Gandalf's is **PID 52123, port 8080**. A
  leftover rehearsal gateway is **PID 3593861, port 8090** (OpenShell 0.0.101,
  binaries at `~/gandalf-bringup/openshell-0.0.101/bin/`). **Do not confuse
  them.** The 8090 one is disposable; no sandbox was ever registered there.
- **`nemohermes gandalf doctor` always exits non-zero on this host.** It checks
  for a legacy `openshell-cluster-*` container that package-managed gateways do
  not have (upstream confirms: `nemoclaw-src/src/lib/onboard.ts:1969-1971`).
  **Not a usable health gate** — use `ops/status.sh`. Do not "fix" it by
  creating the container.
- **Never restart vLLM or argo-shim** — argo-shim's SSH tunnel needs an
  interactive Duo approval.
- **`ops/snapshot.sh` is fake** — no exit-code check, reports success on empty
  output. Use `ops/backup-sandbox.sh` (manifest-driven, exits non-zero).
- **Do not run `upgrade-sandboxes --auto` or the maintained installer.** The
  installer overwrote `~/.local/bin` on 2026-08-20; `XDG_BIN_HOME` does **not**
  redirect it (it derives target from `dirname $(command -v openshell)`).
- **Build with `NEMOCLAW_INSTALLING=1`** or `prepare` flips the global npm link
  as a side effect.
- **Ask before** pushing, restarting shared services, or touching agent state.
- **Luoji is male** (Three Body Problem). Use "he".

---

## The plan

Order is **cecat first, then luoji** — cecat has 0 FALDA atoms, no tap, no
Sibline bridge, and 1 channel. The cheaper lesson.

Each step ends with a verification. **Do not start step N+1 until N verifies.
If a verify fails, stop and report — do not work around it.**

### Step 0 — File the upstream bug (operator action, unblocks nothing)

Body is already written in `docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md`. Post to
https://github.com/NVIDIA/NemoClaw/issues. **The operator must do this** — it
posts publicly under his account. Independent of everything below.

### Step 1 — P3-1: enumerate cecat's egress needs (read-only)

**Blocks onboard.** Under OpenShell the L7 proxy gates `exec` too; today it is
ungated. **Any host missed becomes a silent 403, not a visible error.**

- Walk cecat's 11 runbooks and 8 scripts; list every host/port reached.
- Include indirect reachers: Google APIs, Slack, model endpoints, package
  registries used at runtime.
- Draft an egress preset modeled on `bringup/50-openshell-policies/*.yaml`.

**VERIFY:** the host list is derived from reading every runbook and script, not
sampled. Cross-check against her live container's outbound connections.

### Step 2 — P3-2: decide the `/shared` mechanism

**Blocks onboard, irreversibly.** `--host-mount` is declared **at onboard time
and cannot be attached later**. Get it wrong and the sandbox must be recreated.

Evaluate, in order:
- read-only host mount for host→agent (PAUSE sentinels, runbooks,
  `/scripts/*.py`, `CALENDAR.md`) — instant, not sync-delayed;
- `nemoclaw sandbox share` (SSHFS) for agent→host (outbox, `TODO.md`);
- polling shuttle as fallback (the pattern Gandalf's Sibline bridge uses).

**Note:** the richer hybrid options were described as `v0.0.110` features in the
old plan. **Re-verify what `v0.0.55` actually supports** — `nemoclaw --help`
lists `share mount|unmount|status`, so SSHFS appears present, but confirm
`--host-mount` exists on this version before designing around it.

**VERIFY:** the chosen mechanism is confirmed available on `v0.0.55` by
`--help` output or source, not assumed.

### Step 3 — P3-3: onboard cecat's sandbox on `v0.0.55`

- Take a backup first: `bash ops/backup-sandbox.sh` (Gandalf's — protects the
  known-good agent, since both share the port-8080 gateway).
- Onboard with the Step 1 egress preset and Step 2 mount decision applied.
- Use `NEMOCLAW_INSTALLING=1`. Do not touch the installer.

**VERIFY:** sandbox reaches Ready; **Gandalf is still healthy** (PID 52123 alive,
port 8080 bound, `~/.nemoclaw/sandboxes.json` `defaultSandbox: gandalf`,
`ops/status.sh` green).

### Step 4 — P3-4: port cecat's workspace and re-point Google auth

- Move her workspace into the sandbox.
- Re-do Google auth via `gog` + upload (mirrors `ops/reauth-google.sh` and
  `post-rebuild.sh` §2).
- Preserve her `#agent-cecat` Slack channel binding **exactly** — one Slack bot
  identity routes by channel.

**VERIFY:** she answers in `#agent-cecat`; a Google call succeeds from inside
the sandbox.

### Step 5 — P3-5: verify end to end, then P3-6 cut over

- Exercise her runbooks; watch for silent 403s (the Step 1 failure mode).
- Confirm heartbeat liveness.
- **Keep the old Compose sandbox until confidence holds.** Do not delete.

**VERIFY:** every runbook exercised, no 403s in the OCSF/gateway log.

### Step 6 — P4: migrate luoji

**Strictly after cecat is fully working.** He additionally carries a live FALDA
tap (needs the Q2 rewrite), the Sibline bridge, Sage MCP, `bundle-mcp`
(**unverified — check before cutover**), and 3 channels.

### Step 7 — cleanup (P1-6)

Retire the leftover rehearsal gateway: PID 3593861 / port 8090,
`~/.local/state/nemoclaw/openshell-docker-gateway-8090/`,
`~/.nemoclaw/gateways/8090/`. **Confirm PID 52123 is untouched.**

---

## Deliberately NOT in this plan

- **Any version upgrade.** Blocked; revisit only when NVIDIA ships a fix.
  Re-test trigger: `grep -n 'GB10' src/lib/readiness/platform-qualification.ts`
  in a new tree, or run a rehearsal onboard on port 8090.
- **Retiring chattpc26** (old P5) — harvest his 16 runbooks as skill-design
  input first.
- **Runbooks → skills conversion.** Separate pass.
- **Opus 5 / Sonnet 5 model change** — committed to `spark-ai/config.yaml`,
  deliberately not applied. New sandboxes pick it up when built.
- **state.db pruning / log rotation.** Three unbounded-growth instances noted
  (`state.db` 1.2 GB, `cron/output` 313 MB, `openshell-gateway.log` 530 MB).
  One fix, later.

## Uncommitted state at handoff

Modified: `README.md`, `docs/FOLLOWUPS.md`, `ops/shutdown.sh` (pre-existing,
operator's). New: `docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md`. Untracked:
`ops/phase0-runner.py` (operator's). **Nothing committed, nothing pushed.**

## Working agreement for the executing session

Do **one step at a time** and report at each boundary. Do not read the 700-line
DGX-Spark plan whole — pull §P3 from it only when needed. This file plus
`docs/FOLLOWUPS.md` is sufficient context to start.
