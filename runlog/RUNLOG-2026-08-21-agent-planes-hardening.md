# 2026-08-21 — Agent-plane hardening: containment gap, memory repair, workspace sync

Follow-on to the same day's three-control-plane work (cecat :8090, luoji :8091
alongside Gandalf :8080). Nothing was cut over; the old `openclaw-gateway` stack
still serves both agents. This entry records four non-obvious findings.

## 1. The iptables rules did not cover the new sandboxes

`OpenClaw-Tutorial` §2.4 specifies three `DOCKER-USER` DROP rules (LAN,
Tailscale CGNAT, SSH). They were written against `172.18.0.0/16`. OpenShell
puts its sandboxes on a **different** Docker network — `openshell-docker`,
`172.19.0.0/16` — so none of the three matched them.

Connect *timing* is what proves it, because a DROP and a refusal look identical
to a plain success/fail check:

| From | LAN gateway :22 | LAN host :22 |
|---|---|---|
| old sandbox (172.18) | 6039 ms timeout — DROPped | 6045 ms timeout — DROPped |
| new sandbox (172.19) | 45 ms refused — arrived | 48 ms **connected** |

Fixed with `ops/fix-sandbox-iptables.sh`. That run also covered
`172.17.0.0/16` — Docker's **default bridge** — which had never been covered and
predates this migration entirely: any `docker run` without `--network` lands
there. Re-verified after: both LAN targets now time out from the new sandbox.

**Tailscale is a separate, pre-existing gap on BOTH stacks** — the CGNAT rule
does not stop reaching a peer that has a direct LAN path. Not caused by the
migration; don't conflate them.

Persistence is unproven until a reboot; re-run `--check` after the next one.

## 2. The drift-checker was structurally unable to detect that

`check-iptables.sh` asserted the three known rules *exist*. They did — so it
logged `all 3 DOCKER-USER DROP rules present` at 05:23 the very morning the gap
was found. **Asserting that known rules still exist cannot detect a new network
escaping their scope.** Only enumeration can.

It now discovers subnets via `docker network ls` and checks all three rules per
container-bearing subnet. Generalizable lesson: a checker written against a
fixed inventory reports health about the inventory, not the system.

## 3. Memory search was broken on both new sandboxes — §E6.0, again

`agents.defaults.memorySearch` was unset, so OpenClaw applied its own default of
`openai` with no key. The old stack has `provider: "none"`; the new sandboxes
did not inherit it. Per the tutorial this is *worse* than FTS-only: a configured
remote provider fails closed, so you lose the free keyword search too.

Fixed (`provider: none` + `memory index --force`). Now matches the §E6.0 healthy
signature: luoji `28/28 files · 43 chunks`, cecat `42/42 · 164 chunks`,
`FTS: ready`. This is the failure that ran silently for five months on the old
stack, and it would have shipped again — **set it explicitly at onboard time for
any future sandbox.**

## 4. Two sandbox gotchas worth an hour each

**The gateway runs in a different network namespace from `docker exec`**
(`pid=1` → `net:[4026533982]`, gateway → `net:[4026534126]`). So
`openclaw doctor` via `docker exec` *always* reports
`Gateway connect failed: 1006` and `/dev/tcp/127.0.0.1/18790` is genuinely
refused — a different loopback. The gateway is listening fine; confirm with
`nsenter -t <pid> -n ss -ltnp`. **Never wire a health check to doctor's gateway
probe here.** Use the gateway's own log (heartbeats + `model-fetch status=200`).

**Always `docker exec -u sandbox`.** Plain `docker exec` is uid 0. Root-run
diagnostics created `openclaw-agent.sqlite` as `root:sandbox 0600`, which the
gateway's own user could not open — `memory index` failed with `unable to open
database file`. Same trap applies to `docker cp`, which preserves the host uid.

## 5. Workspace sync — `ops/apply-agent-workspace.sh`

An agent workspace is three things, not one, and conflating them is what dropped
64 of cecat's 103 files during the migration:

| | source of truth | synced? |
|---|---|---|
| config (SOUL.md, runbooks, PATHS.md) | git | `--push`, git-tracked only |
| memory (`memory/*.md`) | the LIVE copy | never pushed; `--backup-memory` archives |
| runtime (heartbeat-state.json, sessions) | whoever is running | never, either direction |

**`.gitignore:1` is `**/memory/`** — agent memory has never been in git, by
design (inbox metadata: names, addresses, message IDs). Only 20 of luoji's 53
files and 32 of cecat's 103 are tracked. A naive git→sandbox push would have
deleted every memory file.

Deliberately does not use `openshell sandbox upload`: its `.gitignore` filtering
caused the original data loss, and `--no-git-ignore` creates the opposite bug
(pushing runtime state over a live agent). An explicit git-derived file list via
`docker cp` can do neither.

Verified by exercising it: appended a marker to `luoji/PATHS.md`, confirmed
`1 of 20` in dry-run, pushed, checked ownership landed `sandbox:sandbox`, then
reverted. Config reload is hot (`gateway.reload.mode=hot`) — no restart needed.

First backups taken: luoji 28 files, cecat 49, under
`~/.agent-memory-backups/<agent>/<UTC-stamp>/`, mode 700, outside the repo.

## State at end of session

Six containers: 3 OpenShell sandboxes (gandalf, cecat, luoji) + 3 old OpenClaw.
**The old stack is still the real agents** — it holds all 4 Slack routing rules.
The new sandboxes have workspaces and memory but no Slack tokens, no `/shared`,
no `gog`. Gandalf untouched throughout and verified healthy after every step.
