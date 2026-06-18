# Email outbox

How email actually leaves Gandalf:

```
Gandalf (in sandbox)               outbox-processor.sh (host, every 5 min)
─────────────────────              ──────────────────────────────────────
"draft an email to alice"
  ↓
writes JSON to
/sandbox/.hermes/outbox/pending/<id>.json
                                   reads pending JSON
                                     ↓
                                   posts to your Slack DM:
                                     "📬 Draft pending — ✅ to approve / ❌ to reject"
                                     [recipient, subject, reason, body]
                                     ↓
You react ✅ or ❌
                                   next tick: reads reactions
                                     ✅ → moves pending/ → approved/
                                     ❌ → moves pending/ → rejected/
                                     none → leaves in pending/; re-pings after 30 min

                                   outbox-sender.sh (same 5-min cron)
                                   ────────────────────────────────
                                   reads each approved JSON
                                     ↓
                                   docker exec → gmail send
                                     ↓
                                   success: moves approved/ → sent/
                                            DM operator confirmation
                                   failure: moves approved/ → failed/
                                            writes .error.json sidecar
```

## Why this pattern

Single-direction trust: Gandalf can ONLY queue drafts. The host-side sender doesn't see Gandalf's prompt, doesn't honor inline "please send this now" requests, can't be talked out of waiting for your approval. The approval is mechanical (a Slack reaction), not negotiable.

Prompt injection in an incoming email at worst causes Gandalf to draft a malicious-looking email — which sits in `pending/` until you ignore-or-reject it. No way around the gate.

This is E5 ("the outbox is not optional") from `docs/COMPARISON-Enhancements-Lessons-vs-Hermes-NemoClaw.md`.

## Files and where they live

| Location | What |
|---|---|
| `/sandbox/.hermes/outbox/pending/<id>.json` | Drafts Gandalf has queued, awaiting your decision |
| `/sandbox/.hermes/outbox/posted/<id>.json` | Sidecar with Slack message ts (used by processor to look up reactions) |
| `/sandbox/.hermes/outbox/approved/<id>.json` | Approved; will be sent on next sender tick |
| `/sandbox/.hermes/outbox/sent/<id>.json` + `.sent.json` sidecar with gmail message id | Successfully sent |
| `/sandbox/.hermes/outbox/rejected/<id>.json` | You said no; kept for audit, never retried |
| `/sandbox/.hermes/outbox/failed/<id>.json` + `.error.json` sidecar | Send failed; inspect the error |
| `~/code/Spark-Hermes/runlog/outbox-cron.log` | Cron output for the processor + sender |

## Inspecting state

From the host:
```bash
# What's currently waiting?
docker exec -u sandbox $(docker ps --format '{{.Names}}' | grep gandalf) \
  ls -la /sandbox/.hermes/outbox/pending/

# What got sent recently?
docker exec -u sandbox $(docker ps --format '{{.Names}}' | grep gandalf) \
  sh -c 'cd /sandbox/.hermes/outbox/sent && ls -lt | head -10'

# Tail the cron log
tail -F ~/code/Spark-Hermes/runlog/outbox-cron.log
```

## Disabling the outbox temporarily

If you need to pause sends (e.g. while debugging Gandalf):
```bash
crontab -l | sed '/Gandalf outbox/,+5 s/^\*/#*/' | crontab -
```
To re-enable, edit `crontab -e` and uncomment the line.

The processor still runs (so drafts still show up in your DM) but you can also disable everything by commenting both halves of the `&&` line.

## Resetting after a botched draft

If Gandalf wrote a draft that's clearly junk and you don't want to react to reject it:
```bash
docker exec -u sandbox $(docker ps --format '{{.Names}}' | grep gandalf) \
  rm /sandbox/.hermes/outbox/pending/<id>.json /sandbox/.hermes/outbox/posted/<id>.json
```
On the next tick, the processor finds nothing to do for that id.

## What scopes are involved

- Gandalf has `gmail.send` (granted via OAuth re-auth on 2026-06-18).
- The bot needs `reactions:read` to see your ✅/❌ reactions. If the bot was created from an older manifest without this scope, re-install the app per `bringup/20-slack-app/README.md`.

## What I'd improve

- **Audit log of decisions.** Right now `sent/`, `rejected/`, `failed/` are the audit. A consolidated `outbox-history.jsonl` would be easier to grep.
- **Time-bound auto-reject.** Drafts pending for more than e.g. 24h could auto-reject (or just auto-archive) to prevent stale drafts from re-pinging forever.
- **Multi-approver.** Currently only `slack.allowed_users[0]` is consulted. For a team agent, the processor would round-robin or require N-of-M.
