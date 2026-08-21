# Follow-ups / backlog

Deferred items that aren't blocking current work. Check this off as they're done.

## OPEN — sandbox LAN containment gap on the OpenShell agent planes (2026-08-21)

**The three `DOCKER-USER` DROP rules do not cover the OpenShell sandboxes.**
They are scoped to `172.18.0.0/16` (the old `qwen3-coder-next_nim_net`).
OpenShell puts its sandboxes on `openshell-docker`, **`172.19.0.0/16`**, so the
LAN and SSH rules simply do not match them.

Confirmed by behaviour, not inference — connect timing separates a DROP
(silently discarded, hangs to timeout) from a packet that actually arrived:

| From | `<lan-gateway>:22` | `<lan-host>:22` |
|---|---|---|
| old sandbox (172.18) | 6039 ms timeout — DROPped | 6045 ms timeout — DROPped |
| new sandbox (172.19) | 45 ms refused — arrived | 48 ms **connected** |

A sandbox on the new planes can open a TCP connection to a host on the LAN, on
port 22. The old ones cannot see it at all.

**Not urgent today** — the new sandboxes hold no Slack tokens and take
instructions from no one. It becomes load-bearing the moment they do, so it
**gates the Slack cutover** (Phase E of the cutover plan).

**Fix:** `ops/fix-sandbox-iptables.sh` — mirrors the three existing rules for
`172.19.0.0/16`. Needs sudo; run it manually.

**Tailscale is a separate, pre-existing gap affecting BOTH stacks.** The CGNAT
rule does not stop reaching a peer that has a direct LAN path (verified:
`<a-tailscale-peer>:22` connects from the old sandbox too). Not caused by the
migration; do not conflate the two.

**The drift-checker could not see this class of bug — FIXED 2026-08-21.**
`spark-ai-agents/shared/scripts/cron/check-iptables.sh` asserted the three rules
*exist* against a hardcoded `172.18.0.0/16`. They did, so it logged
`iptables-check OK | all 3 DOCKER-USER DROP rules present` — at 05:23 the very
morning this gap was found. Asserting that known rules still exist cannot detect
a *new network escaping their scope*; only enumeration can.

It now discovers subnets via `docker network ls` and asserts all three rules per
subnet that has containers on it (container-free networks are logged, not
alerted). Verified against the live host: it flags 3 of 6 missing, all
`172.19.0.0/16`. It lives in ROOT's crontab at `23 5 * * *` — cron has no
`TZ=` line there, so that is **05:23 local**, installed by
`shared/scripts/ops/install-iptables-cron.sh`. Not in catlett's crontab, which
is why it looked unscheduled. (The log stamps are UTC, hence the `10:23Z`
entries.)

Rules applied 2026-08-21 via `ops/fix-sandbox-iptables.sh`. That run also
covered `172.17.0.0/16` — Docker's **default bridge**, uncovered since before
this migration: any `docker run` without `--network` lands there. Verified
after: new luoji sandbox now times out to both LAN targets
(was 45 ms refused / connected). Old sandboxes, both agent planes, and Gandalf
all unaffected. **Persistence is unproven until a reboot** — re-run
`fix-sandbox-iptables.sh --check` after the next one.

## Gotchas on the OpenShell agent sandboxes (2026-08-21)

Three things that will waste an hour each if not known.

**1. The gateway runs in a DIFFERENT network namespace from `docker exec`.**

```
pid=1    net=net:[4026533982]   ← where docker exec lands
pid=432  net=net:[4026534126]   ← where openclaw-gateway lives
```

So `openclaw doctor` via `docker exec` always reports
`Gateway connect failed: gateway closed (1006 abnormal closure)`, and
`/dev/tcp/127.0.0.1/18790` is genuinely refused — that is a *different*
loopback. The gateway IS listening; confirm with:

```bash
docker exec -u root <con> nsenter -t <gateway-pid> -n ss -ltnp
# LISTEN 0 511 0.0.0.0:18790 users:(("openclaw-gatewa",pid=432,fd=32))
```

**Do not wire a health check to doctor's gateway probe** — it is a guaranteed
false negative here. Use the gateway's own log (heartbeats + `model-fetch
... status=200`) as the liveness signal instead. Doctor's *systemd* finding is
separately benign: NemoClaw supervises the gateway itself.

**2. Always `docker exec -u sandbox` when touching sandbox state.** Plain
`docker exec` is uid 0. Diagnostic commands run as root created
`agents/main/agent/openclaw-agent.sqlite` owned `root:sandbox 0600`, which the
gateway's own `sandbox` user then could not open — `memory index` failed with
`unable to open database file`. Fixed with `chown sandbox:sandbox`. A
root-owned artifact under `/sandbox/.openclaw/` is latent breakage.

**3. Memory search was broken on BOTH new sandboxes — the §E6.0 bug, again.**
`agents.defaults.memorySearch` was unset, so OpenClaw applied its own default of
`openai` with no API key. The old stack has `provider: "none"`; the new
sandboxes did not inherit it. Per the tutorial this is *worse* than FTS-only —
a configured remote provider fails closed, losing the free keyword search.

Fixed 2026-08-21 (`provider: none` + `memory index --force`), now matching the
§E6.0 healthy signature — luoji `Indexed: 28/28 files · 43 chunks`, cecat
`42/42 · 164 chunks`, `FTS: ready` on both. `Embeddings: unavailable` is
expected and correct in FTS-only mode.

**Any future sandbox needs this set explicitly at onboard time.** It is a silent
failure: nothing surfaces it, which is how it ran for five months on the old
stack.

## RESOLVED 2026-08-21 — agent shell shares a container with its config (ACCEPTED)

Under OpenShell the OpenClaw gateway runs **inside** the sandbox
(`/sandbox/.openclaw/`, as user `sandbox`), the same container and user that
agent shell commands run as. The old stack kept them in two containers:
`openclaw.json` did not exist inside `openclaw-sbx-agent-*` at all. **Charlie
reviewed and accepted this 2026-08-21. Do not re-litigate.**

Measured, not assumed:

- **No exfiltration path.** The sandbox has no working DNS
  (`curl https://example.com` → `Could not resolve host`). The only route out is
  the OpenShell L7 proxy at `10.200.0.1:3128`, which **denies by default** —
  `example.com`, `pastebin.com`, `api.telegram.org`, `api.anthropic.com` all
  return `CONNECT tunnel failed, 403`. Only `inference.local` returns 200. The
  allowlist lives in the control plane on the host; nothing in the sandbox can
  edit it.
- **No literal credentials in the container.** `COMPATIBLE_API_KEY` is
  `openshell:resolve:env:<id>` — a reference. The real value appears in no
  process environment the agent can read; `/proc/1/environ` is denied;
  `/sandbox/.openclaw/credentials/` is empty. Same indirection CLAUDE.md already
  documents for Gandalf.
- **What IS real:** `openclaw.json` is mode `0660 sandbox:sandbox` — writable by
  the agent's own user (verified by writing a key and reading it back; restored
  byte-identical, hash `OK`). The `/config` *chat* command is disabled
  (`isCommandFlagEnabled` returns `=== true`, so absent = off — this matches the
  old stack's explicit `config: false`; **do not "fix" it**), but a shell command
  can do what `/config` cannot.

**Impact is misconfiguration, not exfiltration.** An agent could disable its own
guardrails, swap its model, or corrupt the file into a boot failure. It cannot
open a new egress path that way — `openclaw.json` has no authority over the
proxy allowlist.

**Net: stronger than the old stack.** Old had real credentials in gateway env,
`docker.sock` mounted rw, and L3-only egress that permitted outbound HTTPS to
anywhere by design (OpenClaw-Tutorial §2.4 says so explicitly). New has no
literal secrets, no socket, and default-deny L7 egress. Tutorial §2.1 threat 4
(credential exfiltration via unrestricted outbound HTTP) is *better* mitigated.

If ever revisited, the cheap fix is root-owned `0640` on `openclaw.json` —
readable by `sandbox`, not writable. Needs testing across a restart, and
NemoClaw may reset ownership on rebuild.

**Tutorial §2.4's containment table is now wrong for these two agents** (it
claims a throwaway inner sandbox per command and `commands.config: false`).
Correct it at cutover — see Phase H of the cutover plan.

## Platform upgrade — RESOLVED 2026-08-21: don't upgrade, run two control planes

**cecat is live under NemoClaw/OpenShell alongside Gandalf. Nothing was upgraded.**

The week of "upgrade, then migrate" was solving the wrong problem. The goal was
never to upgrade Gandalf — it was to run a second agent. Those are independent,
because OpenShell supports **multiple control planes on one host**:

| | Gandalf | cecat | luoji |
|---|---|---|---|
| Control plane | `nemoclaw` @ :8080 | `nemoclaw-8090` @ :8090 | `nemoclaw-8091` @ :8091 |
| NemoClaw | v0.0.55 (global npm) | v0.0.108 (sidecar) | v0.0.108 (sidecar) |
| OpenShell | 0.0.44 (`~/.local/bin`) | 0.0.101 | 0.0.101 |
| Registry | `~/.nemoclaw/sandboxes.json` | `~/.nemoclaw/gateways/8090/…` | `~/.nemoclaw/gateways/8091/…` |
| Inference route | `vllm-local / claudeopus47` | `compatible-endpoint / claudesonnet46` | `compatible-endpoint / claudeopus47` |
| Dashboard | — | :18789 | :18790 (auto-allocated) |
| Driver | `source ops/cecat-env.sh` | ↑ | `source ops/luoji-env.sh` |

All three verified answering real prompts on 2026-08-21, concurrently. Gandalf's
route stayed at version 10 throughout both onboards — **the "a second onboard
steals the first agent's inference route" fear is empirically disproven on this
host.** The env scripts change ONE shell only; the global `nemoclaw`/`openshell`
stay pinned to Gandalf's versions, so every existing ops script is untouched.
**Gandalf was never upgraded, rebuilt, or restarted.**

### ONE CONTROL PLANE PER AGENT — this is the load-bearing rule

The OpenShell inference route (what `inference.local` resolves to) is **one per
control plane**, shared by every sandbox on it. luoji runs `claudeopus47` and
cecat runs `claudesonnet46`, so putting them on one plane would have silently
re-pointed one of them. That — not registry segregation — is the real reason
each agent needs its own port. Adding a 4th agent means a 4th plane (:8092).

Consequences for things previously believed blocking:

- **The GB10/DMI N1x gate** — never hit. v0.0.108 preflight passed cleanly. The
  bisect was right.
- **The `default` sandbox-namespace problem** — a non-issue. It only bites when
  *migrating an existing container* onto a scoped-namespace gateway. cecat was
  created natively in the new namespace; Gandalf keeps his old gateway.
- **`--host-mount` DOES exist** in v0.0.108 (it did not in v0.0.55), so
  `DECISION-cecat-shared-mechanism.md` can be revisited if `/shared` is wanted.

Two operational gotchas, both now handled in-tree:

1. **v0.0.108 commands flip the GLOBAL default gateway** to `nemoclaw-8090` as a
   side effect of `onboard`/`exec`. That made `ops/status.sh` report
   `Sandbox phase: unknown` while Gandalf was perfectly healthy. `ops/status.sh`
   now pins `-g nemoclaw` and calls `~/.local/bin/openshell` by absolute path
   (`ensure_path` only *prepends* when absent, so a sourced cecat env otherwise
   leaves 0.0.101 ahead on PATH). Restore by hand with
   `openshell gateway select nemoclaw`.
2. **`ops/status.sh`'s long-standing false `Inference: FAIL` is FIXED** — the probe
   was missing the `platforms.api_server.extra.key` bearer token. It now reads
   `~/.config/falda/phase0-api-key.env`. A FAIL there is now real.

### The live OpenClaw stack is UNTOUCHED and still authoritative

Do not confuse the new sandboxes with the running agents. The production stack is
**one `openclaw-gateway` container** (`ghcr.io/openclaw/openclaw:2026.6.11`,
up 2 days) serving BOTH cecat and luoji, each with its own
`openclaw-sbx-agent-*` sandbox container and a bind mount to
`~/code/spark-ai-agents/<agent>`. luoji is the **default** agent there and holds
**3 Slack channel routing rules**; cecat holds 1. All verified intact after both
onboards.

So six containers are running: 3 new OpenShell sandboxes (gandalf, cecat, luoji)
and the 3 old OpenClaw ones (gateway + 2 agent sandboxes). **The old ones are
still the real agents — they hold all the Slack routing.** Nothing has been cut
over.

### Remaining work to actually cut over

Both new sandboxes now carry their **real** workspaces (loaded 2026-08-21; see
the operational notes at the end of this section). What they still lack is
*inbound traffic* — all Slack routing lives on the old gateway.

luoji carries host coupling cecat did not, which must be solved before cutover:
- a `gog` CLI **wrapper** (`~/.local/bin/gog-wrap` shims `/usr/local/bin/gog-real`
  and injects `GOG_KEYRING_PASSWORD` from `/tmp/.config/gogcli/.gog_pw`)
- bind mounts for `~/.config/gogcli` and `~/.local/share/keyrings`
- `GOG_ACCOUNT=tpc26agent@gmail.com`, `GOG_KEYRING_BACKEND=file`
- `/shared` (460M) — the cross-agent email/Slack outbox that `PATHS.md` treats as
  canonical. `--host-mount` exists in v0.0.108 (read-only), so revisit
  `DECISION-cecat-shared-mechanism.md`.

- [x] **Load each agent's identity into its sandbox.** DONE 2026-08-21 — both
  verified self-aware. Note the copies are now **divergent**: the sandbox has its
  own writable copy, while the old container still bind-mounts the git workspace.
  Edits on one side do not reach the other. Pick an authoritative side before
  either is used for real work.
- [ ] **Re-create luoji's Slack routing** (3 channels) and cecat's (1) on the new
  side — or keep the old gateway as the messaging front end. Until then the new
  sandboxes receive no inbound traffic.
- [ ] **Solve luoji's `gog`/keyring coupling** (see above) before his cutover.
- [ ] **Merge `cecat-openshell-migration`** (`5604f4f`, 14 files) in
  `spark-ai-agents` — deliberately unmerged, because merging changes the OLD
  cecat's live behaviour through her bind mount while she is still serving. Safe
  once the old container is retired.
- [ ] **Retire the old containers** (`openclaw-gateway`,
  `openclaw-sbx-agent-cecat-f7952fcc`, `openclaw-sbx-agent-luoji-b88d9626`) only
  once both sandboxes are authoritative. Retiring the gateway kills BOTH agents'
  Slack presence at once.
- [ ] **Add the 5-minute `openclaw cron` tick** for the TODO promotion loop, and
  have `post-rebuild.sh` re-create it — OpenClaw cron is NOT backed up (jobs live
  in `state/openclaw.sqlite`, which the manifest never declares).
- [x] **Reboot survival.** DONE 2026-08-21 — `ops/agent-planes.sh` owns both
  planes and is wired into `~/start-all.sh` (Layer 4b) and `~/shutdown.sh`
  (Group 0), both in the **DGX-Spark** repo. Cold-cycle tested.

---

## Platform upgrade (Hermes / OpenShell / NemoClaw) — historical

> **⚠️ Superseded by the section above — the upgrade turned out to be unnecessary.**
> Kept because the per-tag version matrix is accurate and worth not re-deriving.

> **⚠️ REVISED 2026-08-21. The "stay on v0.0.55" decision below is SUPERSEDED.**
> It rested on testing only `v0.0.110`. A per-tag bisect showed the N1x preflight
> was introduced in **`v0.0.109`** — **`v0.0.108` is clean**, and already has the
> per-port state segregation (PR #6711) and inference route guard (PR #6338) that
> make multi-agent safe. **Plan: upgrade to v0.0.108, rebuild Gandalf, then
> migrate cecat.** Operator approved the rebuild 2026-08-21.
> Full plan: `docs/HANDOFF-2026-08-21b-upgrade-to-v0.0.108.md` (gitignored working
> note — on the host, not published).
>
> Still true: `v0.0.109`+ cannot onboard or rebuild on this host, so the DMI bug
> is still worth filing — v0.0.108 buys a working window, not a permanent fix.

**Superseded (2026-08-20): stay on NemoClaw `v0.0.55` + OpenShell `0.0.44` + Hermes
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
`docs/HANDOFF-2026-08-21-cecat-migration-blocked.md` (gitignored working note).

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

## Agent planes — operational notes (2026-08-21)

`ops/agent-planes.sh {start|stop|status}` owns the :8090/:8091 planes. Wired into
`~/start-all.sh` as Layer 4b and `~/shutdown.sh` as Group 0 (both in the
**DGX-Spark** repo). Cold-cycle tested: both planes stopped fully and came back
in ~2s with both agents answering under their real identities.

Three gotchas worth not rediscovering:

1. **`phase: Unspecified` means the WRONG `openshell` CLI is on PATH.** The
   v0.0.108 CLI shells out to whatever `openshell` it finds first; against
   Gandalf's 0.0.44 binary the phase field decodes as `Unspecified` even while
   `openshell sandbox list` says `Ready`. It is a version mismatch, NOT a sandbox
   problem — do not wait, retry, or recreate. Source `ops/<agent>-env.sh` first.
2. **A relaunched gateway needs its argv0 tag.** NemoClaw identifies its own
   gateways by argv0 `openshell-gateway[nemoclaw=nemoclaw-<port>;port=<port>]`
   (`buildOwnedHostGatewayArgv0` / `HOST_GATEWAY_PGREP_PATTERN`). Started without
   it, the gateway serves traffic fine but the CLI cannot recognise, reuse, or
   reap it — so `onboard --resume` would try to start a duplicate on a port
   already in use. `agent-planes.sh` sets it via a small `os.execv` shim.
3. **`runtime.json`'s pid goes stale.** NemoClaw writes it at onboard time and
   never refreshes it on relaunch, so it names a dead PID after any restart.
   `agent-planes.sh` reads the actual port listener instead.

Also fixed: `openshell gateway select` writes a GLOBAL default that several
v0.0.108 commands set as a side effect. Left on an agent plane it makes Gandalf's
sandbox read as "unreachable" while perfectly healthy — it broke `~/start-all.sh
--check` exactly this way. `agent-planes.sh` now restores `nemoclaw` on EXIT via
a trap, and `ops/status.sh` pins `-g nemoclaw` with an absolute binary path.

Workspaces are loaded: cecat 103 files (49 memory), luoji 53 files (28 memory),
each with NemoClaw's generated POLICY.md preserved and the original stubs kept at
`/sandbox/.openclaw/workspace.stub-backup`. Both confirmed self-aware — cecat
quotes her SOUL.md, luoji names the Wallfacer. **Upload with `--no-git-ignore`:
the default filtering silently dropped 64 of cecat's 103 files, including all of
`memory/`.**
