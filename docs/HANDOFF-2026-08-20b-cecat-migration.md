# Migrate cecat (and later luoji) into NemoClaw/OpenShell — checkpoint 3

**Written 2026-08-20, late session; updated same day after the OPEN QUESTION was
answered. Supersedes `archive/HANDOFF-2026-08-20-openclaw-migration.md`.**
Self-contained; start here. Nothing has been migrated yet.

> **What changed in checkpoint 3.** The OPEN QUESTION (what OpenClaw under
> NemoClaw natively provides) is **answered** — see the next section. Three
> earlier conclusions are now **reversed or resolved**:
> - The shuttle question is **closed: no shuttle is needed.** Slack delivery
>   becomes native, because onboarding moves the gateway *inside* the sandbox.
> - The "RECONSIDER httpx" note is **reversed — stay on curl.** The sandbox
>   image ships no python HTTP client at all.
> - Native `openclaw cron` is **rejected**: its jobs are not backed up and are
>   silently lost on rebuild. CALENDAR.md/TODO.md stay.

---

## Read this first: the mistake that ended the last session

The previous session (same day, earlier) did real work and then **generalized
from the wrong reference implementation.** It studied Gandalf, saw that he does
scheduling and Slack delivery natively via `hermes cron`, and proposed rebuilding
cecat's CALENDAR.md/TODO.md machinery on that basis.

**`hermes cron` is a Hermes feature. cecat is an OpenClaw agent and cannot use
it.** NemoClaw treats the agent runtime as pluggable — `openclaw` is the DEFAULT
(`src/lib/agent/runtime.ts`: `!agent || agent.name === "openclaw"`), and `hermes`
is the special case. An onboarded cecat gets `/sandbox/.openclaw/`, not
`/sandbox/.hermes/`. No `hermes cron`, no `--deliver slack:<id>`, none of the
`/sandbox/.hermes/skills/` tree.

**The correct framing, carried forward:**

> Gandalf is the reference for **sandbox and egress mechanics** — those are
> runtime-independent. He is NOT the reference for **agent-level features**
> (scheduling, delivery, skills), because those come from the agent runtime, and
> cecat's runtime is different from his.

Operator's standing instruction, which still holds: **default to Gandalf's proven
patterns; deviate only after deliberate analysis, and raise the deviation as a
discussion** ("Gandalf does it this way, but X is simpler — here's the tradeoff").
The failure above was deviating on *inference*, not analysis — and in the wrong
direction, toward more machinery rather than less.

**The project's goal is SIMPLIFICATION.** Any proposal that adds moving parts
needs to justify itself against that.

---

## THE OPEN QUESTION — ANSWERED (2026-08-20)

**What does an OpenClaw agent running under NemoClaw/OpenShell natively provide
for (a) scheduling, (b) Slack delivery, (c) skills?**

Answered by reading NemoClaw v0.0.55 source and inspecting the live
`openclaw-gateway` (2026.6.11) and the Gandalf sandbox. Each claim below has a
citation; verify rather than trust if you are resuming cold.

### The finding that drives everything: onboarding INVERTS the topology

**Under NemoClaw the OpenClaw gateway runs INSIDE the sandbox.**
`buildOpenClawRecoveryScript` (`src/lib/agent/runtime.ts:186-207`) launches
`openclaw gateway run --port N` in the container.

Today it is the opposite: `openclaw-gateway` is a *separate* container that
spawns `openclaw-sbx-agent-cecat-*` through the docker socket, and that sandbox
has no `openclaw` binary at all (`command -v openclaw` → not found).

So everything currently "gateway-side" — which the last checkpoint assumed was
therefore *safe from* the migration — actually **moves into the sandbox with
her**. Re-check any conclusion that rests on gateway/sandbox separation.

### (a) Scheduling — native, but its state is NOT preserved

Two native mechanisms, both in-gateway (hence in-sandbox after onboarding):

- **Heartbeat.** Cecat's 15-min cadence is already gateway-side:
  `agents.list[cecat].heartbeat.every` in `openclaw.json`. Not host cron, and
  not managed by `apply-config.sh` (`grep -n heartbeat apply-config.sh` → no
  match); it was hand-written and survives only because apply-config merges.
- **Cron.** `openclaw cron add|list|rm|runs`, scheduled inside the gateway.

**⚠️ Native `openclaw cron` is REJECTED — a rebuild silently loses every job.**
Three checked facts:
1. Cron migrated out of flat files into SQLite. `~/.openclaw/cron/` now holds
   only `jobs.json.bak` and `jobs.json.migrated`, both `{"version":1,"jobs":[]}`.
   The live data is in the `cron_jobs` / `cron_run_logs` tables of
   `~/.openclaw/state/openclaw.sqlite`.
2. `agents/openclaw/manifest.yaml:42-56` declares `cron` in `state_dirs` — now
   an empty husk — and has **no `state_files:` block at all**. Contrast Hermes
   (`agents/hermes/manifest.yaml:92-95`), which declares its DB with
   `strategy: sqlite_backup`.
3. Nothing special-cases it: the backup tars only manifest-declared `state_dirs`
   plus a `workspace-*` glob (`src/lib/state/sandbox.ts:1053-1058`).

The `sqlite_backup` machinery exists and works — it is simply never invoked for
OpenClaw. This looks like an **upstream bug** (the manifest was not updated when
OpenClaw moved cron into SQLite), and we cannot upgrade to get a fix. So the
rebuild reports success and the jobs are gone.

### (b) Slack delivery — native; the outbox and the shuttle both die

Because the gateway is in the sandbox, in-sandbox code can call
`openclaw message send --channel slack --target <id>` directly. The bot token
arrives as an OpenShell placeholder resolved at the egress boundary
(`scripts/generate-openclaw-config.py:558-563`), never as plaintext on disk —
an improvement on today's mode-600 `~/.config/slack/bot_token`.

This deletes `/shared/slack/outbox/`, `send-slack.sh`, its host crontab entry,
and **the entire shuttle question**. See the "Rejected: the host-side shuttle"
section below, whose caveat is now void.

### (c) Skills — real, but not Hermes-shaped

`nemoclaw <name> skill install` uploads to `/sandbox/.openclaw/skills/<name>`
and truncates `sessions.json` to force rediscovery (`src/lib/skill-install.ts:96-113,279-287`).
Gating is per-agent allowlists plus load-time environment checks — **not**
Hermes-style tags. Cecat has no skills today; her runbooks are plain markdown
found by literal path, and can stay that way.

### Two structural limitations to design around

1. **The generator writes only `agents.defaults` — never `agents.list` or
   `bindings`.** A NemoClaw sandbox is effectively **one agent**, bound to
   whatever Slack channels the allowlist permits. Cecat's per-agent heartbeat
   override and her channel binding both live in structures the generator will
   not emit. Reachable only via `NEMOCLAW_AGENT_HEARTBEAT_EVERY` at image-build
   time, `nemoclaw config set`, or hand-editing `openclaw.json`.
2. **The sandbox image has no scheduler of any kind.** Verified against
   `openshell/sandbox-from:1782570229`: `crontab`, `cron`, `crond`, `anacron`,
   `at`, `systemctl`, and even `busybox` are all MISSING. `check-todos.sh`
   therefore cannot simply move in-sandbox as a crontab line.

---

## CALENDAR.md / TODO.md — the operator's design, and why it stands

The previous session proposed replacing these. **The operator pushed back, and
was right.** Capture of that exchange, because it is load-bearing:

**The original design:**
- `CALENDAR.md` holds recurring duties (`DAILY 13:00 | PLAN: <runbook>`).
- A host cron (`check-todos.sh`, every 5 min) reads CALENDAR.md and writes
  `READY` lines into `TODO.md` when an entry comes due.
- The agent reads TODO.md, executes READY items, marks them COMPLETED.
- `_ON_FAILURE.md` implements a `[retry 1/2]` → `[retry 2/2]` → escalate ladder.

**Why it was built that way (operator's rationale, verbatim in substance):**
1. The agent adds work to **a file it owns**, rather than modifying the system
   crontab.
2. It keeps **complexity out of cron** — one dumb host job, all logic in markdown
   the agent and operator can both read.
3. The agent **cannot** remove or corrupt system crontab entries, or another
   agent's entries.

**What was verified about `hermes cron` (for context only — NOT available to
cecat):** it is not Unix cron. There is no `crontab` binary and no cron daemon in
the sandbox at all; jobs live in `/sandbox/.hermes/cron/jobs.json`, mode 600,
sandbox-owned, per-container. So it *would* have satisfied all three goals for a
Hermes agent. It is irrelevant to cecat.

**Conclusions to carry forward:**
- CALENDAR.md/TODO.md stay unless OpenClaw offers something demonstrably simpler.
- Even if a native scheduler exists, note what CALENDAR.md gives the OPERATOR
  that JSON does not: human-readable, hand-editable, comment-out-a-line.
- TODO.md's **queue + retry** function is separate from CALENDAR.md's
  **scheduling** function. Do not conflate them (the previous session did).
  The `[retry N/2]` ladder has no obvious native equivalent anywhere.

### RESOLVED — CALENDAR.md/TODO.md STAY, and the test was met on merit

The native alternative is not merely less pleasant, it is **less correct**:
`openclaw cron` jobs are silently lost on rebuild (see the OPEN QUESTION answer
above). CALENDAR.md lives in `workspace`, which IS a declared `state_dir` and
does survive. This is a correctness argument, not a preference.

**Where the promotion loop runs after migration.** `check-todos.sh` currently
runs from the host crontab and edits CALENDAR.md/TODO.md through a bind mount
that will not exist. The sandbox has no cron daemon either. The available
mechanism is a single deterministic OpenClaw cron entry:

```
openclaw cron add --every 5m --command '<check-todos.sh equivalent>'
```

`--command` payloads run as `sh -lc` and are explicitly deterministic — they
"run inside the Gateway scheduler without starting a model-backed isolated agent
turn", with stdout/stderr captured into run history
(`/app/docs/automation/cron-jobs.md:127`). That is exactly the dumb 5-minute
tick the design calls for.

This **preserves all three of the operator's original rationales**: the agent
still adds work to a file it owns; complexity still lives in markdown, not in
the scheduler; and the agent still cannot corrupt another agent's entries
(there are no other agents in her sandbox).

**Cost, stated plainly:** that one cron entry does not survive a rebuild. The
mitigation is Gandalf's existing pattern rather than a new invention —
`ops/apply-cron.sh` reconciles declared jobs against live ones — so
`post-rebuild.sh` must re-create it. One line of declared state, not a shuttle.

---

## Work completed and still valid

### Step 1 — cecat's egress needs (DONE, valid)

Derived by reading **all 11 runbooks and all 8 scripts** end-to-end, plus
HEARTBEAT.md / CALENDAR.md / PATHS.md / TOOLS.md, cross-checked against the live
container. Draft preset: `bringup/50-openshell-policies/cecat-egress.yaml`.

**Only 3 hosts are sandbox egress:** `oauth2.googleapis.com`,
`gmail.googleapis.com`, `people.googleapis.com`.

Verified NOT hers (do not allowlist):
- **Slack** — she never speaks to Slack. Every runbook writes JSON to
  `/shared/slack/outbox/`; host cron `send-slack.sh` (*/5) delivers it.
- **Ticketmaster** — `check-concerts.py` runs from HOST crontab (`15 9 * * 1,4`).
- **Brave / web_fetch / browser / argo model endpoint** — gateway-side.
- Empirical confirmation: cecat's live sandbox had ZERO established outbound
  sockets; `openclaw-gateway` held the Northwestern (argo) and AWS (Slack) ones.

**`gog` recommendation (unchanged): do not install it in the sandbox.** It is
needed in exactly one place — `RUNBOOK_SLACK_POST.md:65`, `gog contacts search
NAME`, to look up a Slack ID. `contacts-api.py` already does contacts search. The
two `*-harvest-sent-*.sh` scripts that use gog were one-time bootstrap, guarded by
`memory/onetime-sync-complete` (stamped 2026-03-17, already complete). Skipping
gog also drops `accounts.google.com` and `www.googleapis.com` from the preset.

**`binaries:` — verified against the real image** (`openshell/sandbox-from:1782570229`,
the same tag cecat will get per `~/.nemoclaw/sandboxes.json`):

| Path | Present |
|---|---|
| `/usr/bin/python3` | yes |
| `/usr/bin/python3.13` | yes |
| `/usr/bin/curl` | yes |
| `/usr/bin/python3.11` | **NO** — do not list it |

⚠️ **If the curl port survives (see below), the preset MUST include
`/usr/bin/curl`.** The proxy resolves the peer binary of the process that opens
the socket; a python script that shells out to curl is seen as *curl*. Gandalf's
`google-workspace-egress` lists python paths only — copying it verbatim would
fail closed on every Gmail call. `tavily-egress` is the correct model.

### Step 2 — the `/shared` mechanism (DONE — the question dissolved)

Full writeup: `docs/DECISION-cecat-shared-mechanism.md`.

**`--host-mount` does not exist on this stack.** Not in `nemoclaw onboard --help`,
zero matches in the v0.0.55 source tree, and OpenShell 0.0.44's `sandbox create`
has **no bind-mount flag of any kind** — only `--upload` (one-time, create-time
copy). The flag was a v0.0.110 feature described in the old DGX-Spark plan.

Consequence: **there is no irreversible onboard-time decision here.** Step 2 does
not block Step 3. (The old handoff's "get it wrong and the sandbox must be
recreated" warning is void.)

Also established:
- `nemoclaw share mount` exists (SSHFS) but runs the **wrong direction** —
  sandbox→host only. `sshfs` is not installed on the host.
- `openshell sandbox upload/download` both work; `download` on an empty directory
  exits 0 cleanly. NOTE: `upload <file> <dest-path>` creates `dest-path` as a
  DIRECTORY containing the file — not a file rename.
- `exec` takes `-n <name>`; `upload`/`download` take a positional name. Asymmetric.

### urllib → curl port (DONE, but see caveat)

`cecat/scripts/gmail-api.py` and `contacts-api.py` were ported off `urllib`
(which the OpenShell L7 proxy denies at the CONNECT step) to curl-via-subprocess.
Transport only — auth logic, JSON parsing, CLI surface, and the
`RuntimeError: HTTP <code>` / exit-1 error contract are unchanged, so
`_ON_FAILURE.md` retry logic still fires. Still pip-free.

Verified live against Google (host-side): search, `get --format full`, contacts
search found + not-found, OAuth refresh, a `modify` POST, and the 404 path.

Gotcha worth keeping: **curl config files take option names WITHOUT the leading
`--`** when using `name = value`. With dashes, curl parses the line as a URL and
fails `URL rejected: Bad hostname`. Secrets go via a temp `--config` file, never
argv.

⚠️ **CAVEAT — this port is NOT validated against the proxy.** All testing was
host-side, where urllib also worked. It removes a client known to be denied; it
does not prove the replacement is allowed. See "unresolved" below.

✅ **RESOLVED — STAY ON CURL.** The "reconsider httpx" note that stood here is
**reversed**. It rested on "native Hermes plugins use httpx", which does not
transfer to a non-Hermes agent.

Verified against `openshell/sandbox-from:1782570229` (the tag cecat will get):
system python3 is 3.13.5 and **`httpx`, `requests`, `urllib3`, and `certifi` are
ALL missing.** `/usr/bin/curl` (8.14.1) is present. `pip`/`uv` exist, so packages
*can* be installed — but nothing is preinstalled.

Gandalf has `requests`/`urllib3`/`httplib2` only because `ops/post-rebuild.sh:36`
runs `uv pip install --target /sandbox/.hermes/pylibs --python /opt/hermes/.venv/bin/python ...`
and every caller passes `PYTHONPATH=/sandbox/.hermes/pylibs`. That is a
Hermes-specific mechanism re-run after every rebuild, **not an image property**.

Choosing httpx for cecat would mean building her own pylibs layer — install step,
`PYTHONPATH` on every invocation, a `post-rebuild.sh` reinstall — to gain nothing
she needs. The curl port is already written and tested. Keep it, and keep the
scripts pip-free.

Consequence for the preset: `/usr/bin/curl` **must** stay in `binaries:`. The
draft's comment on this is correct and load-bearing.

---

## Rejected: the host-side "shuttle" — read before rebuilding it

The previous session wrote `shared/scripts/cron/shuttle-cecat.sh` (~11 KB) to
emulate bind mounts: copy Slack outbox files sandbox→host so `send-slack.sh`
could deliver them, push TODO.md host→sandbox, plus a lock file, a heartbeat, and
a watchdog added to `run-stack-health.sh`.

**It was deleted**, along with the `run-stack-health.sh` edit (that file is back
to its original state). The script is preserved at
`docs/archive/rejected/shuttle-cecat.sh`.

**Why it was rejected:** Gandalf's `sandbox-scripts/outbox-send.py` docstring
documents that he *already abandoned* this exact pattern — a host-side sender
"had to docker-exec back into the sandbox per call, which doesn't inherit the
OpenShell L7 proxy env vars"; moving it in-sandbox gave "one code path, one set of
failure modes." The shuttle reinvented a deprecated design and added machinery in
a project whose goal is simplification.

**The rejection reasoning was partly wrong, but the rejection stands — and the
question is now CLOSED.** The reasoning was wrong because it assumed cecat could
use *Hermes*-native delivery; she cannot. But the OPEN QUESTION has since shown
she gets *OpenClaw*-native delivery instead: the gateway moves into her sandbox,
so `openclaw message send` works from in-sandbox code.

**Nothing needs to cross the host/sandbox boundary on a schedule. Do not rebuild
the shuttle.** The archived script at `docs/archive/rejected/shuttle-cecat.sh` is
now reference material only.

**One hard-won lesson from it, worth keeping regardless:** the first version had
a "silence alarm" *inside* the shuttle — scan the sandbox outbox for files older
than 30 min. **It can never fire.** If the shuttle runs it has already drained
them; if it is dead the check never executes. A script cannot detect its own
absence. Any liveness check for a delivery path MUST live in a separate,
independently-scheduled process. This was caught empirically, by backdating a file
and watching nothing happen — not by reasoning.

---

## Unresolved / known-unknown

1. **OpenShell egress cannot be validated from the host.** Both probe paths are
   invalid in opposite directions:
   - `docker exec` lands in netns `4026533111` — **completely unenforced**.
     Control test: `example.com`, in NO policy, returned **200**. Any "it works"
     conclusion from `docker exec` is worthless.
   - `nsenter` into the gateway's netns (`4026533314`) breaks peer-binary
     resolution → CONNECT 403 for *everything*, including allowlisted hosts.
     Any "it's blocked" conclusion from `nsenter` is equally worthless.

   The only sound test is a process the gateway itself spawns. **For cecat that
   means her first real exec after onboard.** Do not try to front-run it; a
   previous attempt produced a confident `VERDICT: PASS` that was meaningless.

2. **PAUSE kill switch — mostly resolved; one real decision left.** There is no
   native kill switch (`nemoclaw` has no pause command; the channel-pausing in
   `src/lib/actions/sandbox/doctor.ts:354-399` is about messaging channels, not
   agent turns). So PAUSE stays a sentinel file, now living inside the sandbox.

   **The migration improves it.** Today enforcement is host-side in
   `send-slack.sh`/`send-email.sh`, with HEARTBEAT.md Step 0 as voluntary LLM
   compliance layered on top. After migration the promotion loop is a
   deterministic `--command` job that checks the sentinel and refuses to promote
   — enforcement moves from "the LLM read a file and chose to stop" to "no work
   was ever queued." That satisfies the fail-closed principle.

   **Still to decide:** `PAUSE.global` currently stops *all* agents from one host
   file. Once cecat's sentinel lives in her sandbox and luoji's in his, a global
   pause means writing two files. Decide this deliberately before luoji is
   migrated, rather than discovering it during an incident.

3. **Retry ladder.** `_ON_FAILURE.md`'s `[retry 1/2]`/`[retry 2/2]`/escalate has
   no identified native equivalent in any runtime. Likely stays as-is.

4. **`ops/status.sh` reports a false "Inference: FAIL"** for Gandalf. Its probe
   POSTs to `:8642/v1/chat/completions` with no auth header and gets
   `{"error":"Invalid API key"}`. LiteLLM round-trips fine directly. Pre-existing,
   unrelated to the migration, but it makes the documented health gate unusable.

---

## Gandalf: what was touched, and why

Gandalf is **not** part of this migration. He was used as a test rig (the only
thing on OpenShell today) and as a reference. State verified clean at handoff:
gateway PID 212 alive, container up ~39h, cron back to its original 5 jobs,
`/sandbox/.hermes/` intact, all test artifacts removed.

**One real change, operator-approved:** his host-side port forward for 8642 was
**dead** (PID 53698 gone; pre-existing, not caused by this work — the gateway was
listening fine inside its own netns the whole time). Repaired with the documented
two-liner from `ops/start-all.sh`:

```
openshell forward stop 8642 gandalf
openshell forward start -d 8642 gandalf
```

Now `running` (PID 4054759). Worth knowing this forward can die silently while
every in-sandbox signal stays green.

**Also touched:** one message in Charlie's real mailbox
(`1a01fb581078b5db`, "SATURDAY: Join me for a Town Hall") was marked **unread**
while testing the `modify` POST. Prior read state unknown, so it was left rather
than guessed at.

---

## Uncommitted state

**`Spark-Hermes`** (public — no real identifiers in prose):
- new: `bringup/50-openshell-policies/cecat-egress.yaml` (draft preset)
- new: `docs/DECISION-cecat-shared-mechanism.md`
- new: this file
- new: `docs/archive/rejected/shuttle-cecat.sh`
- moved to archive: `docs/HANDOFF-2026-08-20-openclaw-migration.md`
- pre-existing/operator's: `README.md`, `docs/FOLLOWUPS.md`, `ops/shutdown.sh`,
  `ops/phase0-runner.py`, `docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md`

**`spark-ai-agents`** (private):
- modified: `cecat/scripts/gmail-api.py`, `cecat/scripts/contacts-api.py`
  (urllib → curl)
- `shared/` is gitignored, so the shuttle deletion and the reverted
  `run-stack-health.sh` edit leave no git trace. `run-stack-health.sh` is back to
  original.

**Nothing committed, nothing pushed.**

---

## The settled design (checkpoint 3)

| Concern | Decision | Why |
|---|---|---|
| Slack delivery | **Native** `openclaw message send` in-sandbox | Gateway moves into the sandbox; deletes outbox + `send-slack.sh` + host cron entry |
| Scheduling | **Keep CALENDAR.md/TODO.md** | Native cron is silently lost on rebuild; CALENDAR.md is in a preserved `state_dir` |
| Promotion loop | One `openclaw cron --command` 5m tick, reconciled by `post-rebuild.sh` | No cron daemon in the image; `--command` is deterministic, no LLM turn |
| HTTP transport | **curl** (keep the existing port) | Image has no python HTTP client; httpx would need a whole pylibs layer |
| Shuttle | **Not needed** | Nothing crosses the host/sandbox boundary on a schedule |
| PAUSE | Sentinel file, checked by the deterministic tick | Fails closed — work is never queued, vs. relying on LLM compliance |

## Next steps, in order

1. ~~Answer the OPEN QUESTION~~ — **DONE**, see above.
2. ~~Revisit curl-vs-httpx~~ — **DONE**: stay on curl.
3. ~~Decide the shuttle question~~ — **DONE**: no shuttle.
4. **Decide the multi-agent PAUSE question** (unresolved #2) — the only design
   item left, and it is not a blocker for cecat alone.
5. **Then Step 3 — onboard.** Take a Gandalf backup first (`bash
   ops/backup-sandbox.sh`, NOT `ops/snapshot.sh` which is fake), since both agents
   share the port-8080 gateway. Use `NEMOCLAW_INSTALLING=1`. Do not run the
   maintained installer or `upgrade-sandboxes --auto`.
   **Verify:** cecat Ready AND Gandalf still healthy (PID 52123, `defaultSandbox:
   gandalf`).
6. Steps 4–6 (workspace port, Google re-auth, end-to-end, then luoji) as in the
   archived handoff — luoji strictly after cecat is fully working.

## Landmines (still current)

- **Upgrading is BLOCKED upstream** and is NOT in scope. `v0.0.110` misreads this
  Dell-branded GB10's DMI as a failed N1x and fails closed; gates `rebuild`, not
  just `onboard`; no supported override; patching NVIDIA's source was considered
  and REJECTED. See `docs/UPSTREAM-BUG-nemoclaw-gb10-dmi.md`. Do not re-derive.
- **Two gateways run.** Gandalf's is PID 52123 / port 8080. A leftover rehearsal
  gateway is port 8090 (disposable, no sandbox registered).
- **`nemohermes gandalf doctor` always exits non-zero** on this host — not a
  usable health gate. Use `ops/status.sh` (but see unresolved #4).
- **Never restart vLLM or argo-shim** — argo-shim needs interactive Duo approval.
- **`ops/snapshot.sh` is fake** (no exit-code check). Use `ops/backup-sandbox.sh`.
- **Ask before** pushing, restarting shared services, or touching agent state.
- **Luoji is male** (Three Body Problem). Use "he".
- **Filing the upstream NVIDIA bug is the operator's** and is explicitly NOT in
  the critical path.

## Working agreement

One step at a time; report at each boundary. Verify against the running system
rather than inferring — this session's two significant errors (the meaningless
smoke-test verdict, and `hermes cron` for an OpenClaw agent) both came from
generalizing without checking. When Gandalf's approach seems to apply, confirm the
mechanism belongs to the *sandbox layer* and not to the *Hermes runtime* before
recommending it.
