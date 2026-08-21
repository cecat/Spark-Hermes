# Follow-ups / backlog

Deferred items that aren't blocking current work. Check this off as they're done.

## Platform upgrade (Hermes / OpenShell / NemoClaw) — BLOCKED UPSTREAM

**Decided 2026-08-20: stay on NemoClaw `v0.0.55` + OpenShell `0.0.44` + Hermes
`0.14.0`. Do not upgrade, and do not patch NVIDIA's source to get around this.**

`v0.0.110` cannot onboard *or* rebuild a sandbox on this host: its preflight
misreads our Dell-branded GB10 (`Dell Pro Max with GB10 FCM1253`) as a failed
N1x and exits. Verified from source; no supported override exists. Full analysis
and the ready-to-file report: [`UPSTREAM-BUG-nemoclaw-gb10-dmi.md`](UPSTREAM-BUG-nemoclaw-gb10-dmi.md).

The local-patch option was considered and **rejected**: the fix flips the
machine's *platform identity*, which feeds GPU-route policy and sandbox GPU
preflight — and it would have to be re-applied and re-validated on every future
release. That trades "stale but working" for "current but permanently forked",
which defeats the reason for upgrading.

**⚠️ SUPERSEDED 2026-08-21 — the OpenClaw migration IS blocked by this,
transitively.** The paragraph that stood here said the migration was unaffected
because `v0.0.55` has no N1x preflight. That much is still true: `onboard` will
*run*. But running it is **unsafe**, and the fix is upstream-only:

- `v0.0.55` pins every sandbox to one OpenShell control plane, so a second
  onboard silently re-points Gandalf's inference route (upstream
  [#6315](https://github.com/NVIDIA/NemoClaw/issues/6315)) and a gateway hiccup
  can wipe the shared `sandboxes.json` (upstream
  [#8420](https://github.com/NVIDIA/NemoClaw/issues/8420)).
- The safe mechanism — one gateway per agent via `NEMOCLAW_GATEWAY_PORT`, with a
  segregated state root — landed in PRs
  [#6711](https://github.com/NVIDIA/NemoClaw/pull/6711) and
  [#6338](https://github.com/NVIDIA/NemoClaw/pull/6338) (July 2026), i.e. **after
  `v0.0.55` and before `v0.0.110`** — inside the range this DMI bug blocks.
- `v0.0.55` has the port env var but NOT the state segregation, so moving the
  port alone produces something that looks isolated and is not.

So this bug is the unblocker for the whole cecat/luoji migration, which makes
filing it critical-path rather than optional. Full analysis:
[`HANDOFF-2026-08-21-cecat-migration-blocked.md`](HANDOFF-2026-08-21-cecat-migration-blocked.md).

The P3-1/P3-2 blockers named here are **done**: egress is enumerated
(`bringup/50-openshell-policies/cecat-egress.yaml`) and the `/shared` question
dissolved — `--host-mount` does not exist on this stack, so there is no
irreversible onboard-time decision (`docs/DECISION-cecat-shared-mechanism.md`).

- [ ] **File the bug upstream** at https://github.com/NVIDIA/NemoClaw/issues —
  body is already written in `UPSTREAM-BUG-nemoclaw-gb10-dmi.md`. `v0.0.110`
  shipped 2026-08-18 and is still the newest remote tag, so this is likely
  unreported and a fix could land in the next release.
- [ ] **Re-test when a fix ships.** Cheap check on any new release:
  `grep -n 'GB10' src/lib/readiness/platform-qualification.ts` in the new tree,
  or run the rehearsal onboard on port 8090. If preflight passes, the upgrade is
  unblocked and `docs/PLAN-2026-08-19-upgrade-then-migrate.md` in the
  **DGX-Spark** repo resumes at P1-1 — P0 is already done and its findings hold.
- [ ] **Clean up the P1 rehearsal leftovers** (P1-6). Still running from the
  2026-08-20 attempt: gateway PID 3593861 on port 8090 (OpenShell 0.0.101,
  binaries at `~/gandalf-bringup/openshell-0.0.101/bin/`), plus state at
  `~/.local/state/nemoclaw/openshell-docker-gateway-8090/` and
  `~/.nemoclaw/gateways/8090/`. No sandbox was ever registered there. Gandalf's
  own gateway is PID 52123 on port 8080 — **do not confuse the two.**
- [x] **`nemohermes gandalf doctor` FAIL on `openshell-cluster-nemoclaw not found`
  is a false alarm — explained 2026-08-20.** That container is the *legacy*
  k3s-in-Docker gateway. This host runs the newer package-managed gateway
  (`openshell-gateway` as a plain host process, PID 52123), and upstream's own
  comment at `nemoclaw-src/src/lib/onboard.ts:1969-1971` says so: *"Newer
  package-managed OpenShell gateways do not have an `openshell-cluster-*` Docker
  container, so the live CLI health check is the source of truth."* `doctor`'s
  Gateway check looks for the legacy container unconditionally and reports FAIL
  when it is correctly absent. The adjacent "OpenShell status: connected to
  nemoclaw" check is the one that matters.
  **Consequence: `doctor`'s exit status is not a usable health gate on this
  host — it will always be non-zero.** Use `ops/status.sh`, or read the
  individual checks. Do not "fix" this by creating the container.

**Worth keeping from the blocked rehearsal** (proven, saves re-deriving later):
per-port gateway isolation genuinely works (separate registry, state dir, compat
container, no `setDefault` steal); two OpenShell versions coexist safely because
`install -m 755` replaces the inode rather than writing in place; the one-way
gateway DB migration across 57 releases is a *single additive column*; and the
Gandalf upgrade will need a gateway **relaunch** under the new launcher, not a
binary swap — a swapped binary under the old untagged process still fails
admission.

## Tavily (deferred until after the Telegram bring-up)

Tavily's infrastructure is **implemented and live** (egress host `api.tavily.com`
allowlisted via `bringup/50-openshell-policies/tavily-egress.yaml`;
`TAVILY_API_KEY` in `~/.hermes/.env`, synced into the sandbox by
`ops/post-rebuild.sh` `EXTRA_ENV_KEYS`; confirmed in the running gateway env).
The pivot to Tavily-as-single-host web gateway was committed 2026-06-21
(`ec6e828` + follow-ups). These two loose ends remain:

- [ ] **Verify Gandalf can actually invoke Tavily.** There is no dedicated
  web-search skill in `gandalf/skills/`. Confirm that Hermes' built-in
  web-search tool auto-detects `TAVILY_API_KEY` and calls `api.tavily.com`,
  versus needing a small skill/tool to wire the call. The key + egress are
  necessary but not sufficient if nothing actually issues the request. Quick
  test: have Gandalf perform a web search and confirm an outbound connection to
  `api.tavily.com` in the OCSF/gateway log.

- [ ] **Update the stale `gandalf/skills/openshell-tls-egress` SKILL.md.** Its
  "Allowlist as of 2026-06-21 (after expansion)" section still documents the
  broad ~150-host allowlist and lists NYT, arXiv, AI-vendor blogs, national
  labs, universities, etc. as directly reachable — but the same-day Tavily pivot
  *removed* those from `web-readonly-egress.yaml` and now expects them to be
  fetched through Tavily. Gandalf's own docs therefore contradict the live
  egress policy. Rewrite that section to: "general/arbitrary web → route through
  Tavily (`api.tavily.com`); only the ~15 direct hosts in
  `bringup/50-openshell-policies/web-readonly-egress.yaml` are reachable
  directly." Keep the (still-correct) TLS-injection failure-mode-1 guidance.
