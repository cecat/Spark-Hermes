# 2026-08-08 — Reboot recovery: "sandbox missing or unrecoverable" was a lie

## Symptom

After a host reboot, `ops/start-all.sh` got through every layer and then died:

```
=== Gandalf sandbox ===
[✗] gandalf sandbox missing or unrecoverable. See bringup/10-install-nemoclaw.sh
```

That message points at a fresh install. **Following it would have been
destructive** — the sandbox was intact the entire time.

## Root cause — two independent boot failures

**1. The OpenShell docker-driver gateway daemon (127.0.0.1:8080) does not
autostart at boot.** Nothing owns it: no systemd unit, no restart policy. While
it's down, every `openshell` call fails:

```
Error:   × transport error
  ╰─▶ Connection refused (os error 111)
```

`sandbox_ready()` swallowed that with `2>/dev/null` and `ensure_sandbox()` read
the empty result as "no sandbox exists" → the bringup message. The check could
not tell *"daemon unreachable"* apart from *"sandbox gone."*

Running any `nemohermes gandalf status` starts the daemon as a side effect.

**2. The sandbox container exited 137 at shutdown and Docker did not restart
it.** The policy is `restart: unless-stopped`, but a clean `docker stop` during
host shutdown records the container as *stopped*, so Docker deliberately skips
it on boot. (137 = SIGKILL, `OOMKilled: false` — the shutdown sequence, not a
crash.) OpenShell then latched `Phase: Error / ContainerExited` and never
retried:

```
Sandbox failed to become ready ... reason=ContainerExited Container exited
```

**3. Found while verifying:** `hermes_gateway_healthy()` had been failing
against a healthy gateway. The api_server gained an auth key
(`platforms.api_server.extra.key`) with the phase0 work; the health check sent
no `Authorization` header, so it got 401 forever.

## Fix applied (no rebuild, no snapshot)

`docker start` on the **existing** container, then re-establish the port
forward — which showed `dead` in `openshell forward list`, still pointing at
the pre-reboot PID.

```bash
docker start openshell-gandalf-354307c9-…
openshell forward stop  8642 gandalf
openshell forward start -d 8642 gandalf
```

Back to `Phase: Ready`, Slack + Telegram reconnected, chat round-trip 200.

### Why `docker start` and never a recreate

**The gandalf sandbox has no bind mounts.** Confirmed:

```
$ docker inspect … --format '{{range .Mounts}}…{{end}}'
bind /home/catlett/.local/bin/openshell-sandbox -> /opt/openshell/bin/openshell-sandbox (ro)
```

That is the *only* mount. All of `/sandbox/.hermes` — config.yaml with the
hand-injected `platforms.*` blocks, sessions, memories, pylibs, the patched CA
bundle — lives in the container's **writable layer**. Any recreate/rebuild
discards it. A stopped sandbox container must be *started*, never replaced.

## Code changes

`ops/start-all.sh` (prior version is in git history):

- `ensure_openshell_daemon()` — probe :8080 and start the daemon before
  concluding anything about the sandbox. Distinguishes "can't tell" from "gone".
- `ensure_sandbox()` — find an exited `^openshell-gandalf-` container and
  `docker start` it, with a comment on why it must not be a rebuild. Failure
  message now reports the actual phase.
- `hermes_gateway_healthy()` — send `Authorization: Bearer` from
  `~/.config/falda/phase0-api-key.env` (same file `ops/phase0-runner.py` uses).
- `ensure_hermes_gateway()` — detect a `dead` forward and re-establish it before
  falling back to `nemohermes gandalf recover` (cheaper and lower-risk).

New `~/start-all.sh` — one entry point for all four layers. Thin orchestrator:
argo-shim first (it owns the Duo TTY prompt), then delegates to
`spark-ai/start-all.sh` and `Spark-Hermes/ops/start-all.sh`, then *verifies*
FALDA/Ollama/Sibline without starting them (systemd user units + linger already
own those). `--check` reports without touching anything.

Two steps are called out explicitly rather than left as side effects of the
delegated scripts, because both are load-bearing and were previously invisible:

- **OpenShell daemon** is its own step in layer 3, ahead of the sandbox. This is
  a **hard dependency**, not a warning: the Gandalf sandbox *is* an OpenShell
  sandbox, so if the daemon can't be started the layer aborts immediately rather
  than continuing on to probe the sandbox and gateway. Those probes cannot
  succeed without it, and letting them run buries the one error that matters
  under two derived ones. (`ops/start-all.sh` already had this right — it calls
  `fail`, which exits.)
- **openclaw-gateway** is re-verified from the host after
  `spark-ai/start-all.sh` returns (that script's own check runs from *inside*
  the container, so it can't distinguish "not created" from "unhealthy").

Full run on 2026-08-08 brought `openclaw-gateway` up from nonexistent to
`Up (healthy)`, reaching Argo through the socat bridge (HTTP 200). All four
layers now report healthy.

## What actually needs manual help after a reboot

Everything with a user unit and linger enabled came back by itself: Ollama,
FALDA gateway/tap/distiller, Sibline broker/bridge/shuttle, all `gandalf-*`
socat bridges, LiteLLM. vLLM came back on its restart policy.

Only these do not:

| Component | Why |
|---|---|
| argo-shim | intentional — SSH tunnel needs interactive Duo |
| OpenShell gateway daemon | nothing owns it (bug 1) |
| gandalf sandbox container | `unless-stopped` skips it after a clean shutdown (bug 2) |
| `openclaw-gateway` | container did not exist at all; needs `docker compose up -d` |

## Gotchas worth remembering

- **FALDA health is `/healthz`.** `/health`, `/`, and `/stats` all return **405**
  on this build. Checking `/health` makes a healthy FALDA look dead.
- `gandalf-sibline-shuttle.service` hit `NRestarts=284` while the sandbox was
  down — it `docker exec`s into the sandbox, so it crash-loops until the
  sandbox returns. Self-heals; not a separate fault.
- `openshell forward list` reporting `dead` is the normal post-reboot state
  (stale PID). It is not evidence the gateway is broken — check for the
  `hermes gateway run` process *inside* the container before escalating.

## Boot automation (added same day)

`gandalf-boot-recover.service` (user unit, enabled) now runs
`ops/boot-recover-sandbox.sh` at boot. It does **only** the two things that
don't self-heal: start the OpenShell daemon, then `docker start` the exited
sandbox. No network calls, no inference, no compose, and it never touches
vLLM / LiteLLM / OpenClaw / argo-shim. Idempotent — a no-op when healthy.

Scope was kept this small on purpose. Auto-running the full `~/start-all.sh`
was considered and rejected: argo-shim needs an interactive Duo passcode, so
Layer 1 can never complete unattended, and every boot would produce a
partial-failure report that trains you to ignore the log. It would also give a
boot-time script the ability to restart vLLM — 98.5 GB of a 121 GB unified pool,
the one component here that could plausibly wedge the machine.

Safety mechanisms:

| Mechanism | Setting |
|---|---|
| Kill switch | `ConditionPathExists=!%h/.no-autostart` |
| Hard timeout | `TimeoutStartSec=300` |
| Never crash-loops | `Restart=no` |
| Log | appends to `~/start-all-boot.log` |

```bash
touch ~/.no-autostart    # disarm before rebooting
rm ~/.no-autostart       # re-arm
```

**Gotcha found while testing this:** the kill switch was first written as
`ExecStartPre=/bin/sh -c '[ ! -e %h/.no-autostart ] || exit 1'` together with
`SuccessExitStatus=1`. That combination *silently defeats itself* — systemd
treated the guard's exit 1 as success and ran `ExecStart` anyway. The journal
said "disarmed by ~/.no-autostart" and the script executed regardless. Use
`ConditionPathExists=`, which skips the unit cleanly before any `Exec*` line.

**Lockout risk (the reason to be careful here) is low on this host:**
`ssh.socket` is socket-activated and enabled, so sshd is listening before any
user unit runs; `getty@tty1` is enabled; and a *user* unit can't block
`multi-user.target`. A broken script leaves Gandalf down — it can't lock you out.

### Verified

- disarmed → unit skipped, script never ran, no log written
- armed, healthy → no-op, exit 0, ~10 s
- armed, sandbox exited (stubbed `docker`/`openshell`) → `docker start` called,
  reached Ready
- live sandbox untouched throughout
