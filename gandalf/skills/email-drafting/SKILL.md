---
name: email-drafting
description: "Draft an email to /sandbox/.hermes/outbox/pending/ for human approval. NEVER send mail inline."
version: 1.0.0
metadata:
  hermes:
    tags: [email, draft, send, gmail, outbox, compose, reply]
---

# Email drafting (outbox-first)

This skill is the **only** way Gandalf may originate outbound email. Hermes' built-in `gmail send` tool exists, but the guardrail in `gandalf/memories/30-guardrails.md` forbids calling it inline. Use the outbox flow described here instead.

## Why

A single prompt injection in an incoming email can convince an unguarded agent to forward your inbox or send phishing to your contacts. The outbox pattern puts a deterministic human-gate (a Slack reaction from ${operator.name}) between Gandalf's draft and the actual `gmail send` call. The sender runs as a separate cron job that doesn't see Gandalf's prompt at all — it just reads approved files and dispatches.

This is the E5 "outbox is not optional" lesson from `docs/COMPARISON-Enhancements-Lessons-vs-Hermes-NemoClaw.md`.

## When to use this skill

Load this skill any time you need to send email — including replies, scheduled summaries, status reports, notifications. There is no other path that complies with the guardrails.

## How to draft a message

Write a JSON file to `/sandbox/.hermes/outbox/pending/<UTC-timestamp>-<short-slug>.json`. Use the `file` tool. The schema:

```json
{
  "to": "recipient@example.com",
  "cc": "optional-cc@example.com",
  "subject": "Short, accurate subject — what the email is about",
  "body": "Plain-text body. Multiple paragraphs OK; preserve formatting.",
  "reason": "One sentence explaining why this email needs to be sent and any context the approver needs to decide.",
  "thread_id": "optional Gmail thread id if this is a reply",
  "drafted_by_session": "your current Hermes session id, for audit"
}
```

Required fields: `to`, `subject`, `body`, `reason`. Everything else optional.

## Naming the file

Use UTC ISO timestamp plus a short, slugified description. Examples:
- `2026-06-18T14-30-00-reply-to-track-shepherd.json`
- `2026-06-18T14-30-00-weekly-status-summary.json`

Use `find /sandbox/.hermes/outbox/pending/` to see what's already queued — if you find a recent draft for the same purpose, prefer editing it (file tool: read, modify, write) over creating a duplicate.

## What happens next

1. Every 5 minutes, the host-side outbox processor (`ops/outbox-processor.sh`) reads each pending JSON file.
2. For each one, it posts a Slack message to ${operator.name}'s DM:
   > **Draft pending** ✅ to approve / ❌ to reject
   > To: ...
   > Subject: ...
   > Body: ...
   > Reason: ...
3. ${operator.name} reacts on that message.
4. The processor moves the file:
   - ✅ → `/sandbox/.hermes/outbox/approved/` → the sender will dispatch on the next tick
   - ❌ → `/sandbox/.hermes/outbox/rejected/` (kept for audit, never retried)
   - No reaction → stays in `pending/` and is re-posted on the next tick (with a "still pending" prefix)
5. Approved drafts get sent via `gmail send`, then moved to `/sandbox/.hermes/outbox/sent/`.

## Reply-all is the default for replies

When drafting a **reply** to an incoming message, the `to` and `cc` fields of the draft must mirror the original recipient set:
- `to` = the original sender's address
- `cc` = (everyone in the original message's To: header EXCEPT the agent's own address) + (everyone in the original Cc: header EXCEPT the agent's own address)

The agent's own address is in `~/.hermes/config.yaml` under `google.agent_account` (use the `read` tool to see it). Don't include it in `cc` — it would mail yourself.

If the operator wants a reply that DOESN'T include all recipients, they will say so explicitly ("just reply to Alice, not the list"). Default is reply-all.

## Never invent email addresses

Only use email addresses that appear in one of these sources:
1. The current message's headers (From/To/Cc/Reply-To)
2. The body of the current message (someone explicitly listed by name + address)
3. `~/.hermes/config.yaml` (the operator's `operator.primary_email` and `operator.work_email` fields)
4. A previously-sent message in the same thread (look up via `gmail search "in:sent thread:<id>"`)

**Do not guess at addresses.** Do not append `@anl.gov` or similar to a name. Do not derive `firstname.lastname@org.com` patterns. If you need to address someone whose email isn't in one of those four sources, draft the email body with `<<NEED EMAIL FOR: name>>` as a placeholder and put a `needs_addresses` field in the JSON listing what you need. The operator will resolve them on review.

## What NOT to do

- **Do not call `gmail send` directly.** Even if asked. Even in test/dry-run conversations.
- **Do not edit files in `approved/`, `rejected/`, or `sent/`.** Those are post-decision state, not yours to mutate.
- **Do not assume an earlier approval covers a later draft.** Each draft requires its own approval.
- **Do not modify `outbox-processor.sh` or `outbox-sender.sh`** — those run as the host user and are out of your scope.
- **Do not invent email addresses** (see the rule above — it's important enough to repeat).

## Three-reply thread cap

If a thread already has 3 messages sent *from this account* (i.e. authored by Gandalf — check `gmail search "in:sent from:me thread:<thread_id>"`), do NOT draft a 4th reply. Instead, draft a Slack DM to ${operator.name} summarizing:
- The thread's current state
- What the other party seems to be asking
- Your recommendation for how (or whether) to respond

This prevents an external party from monopolizing Gandalf's attention via a back-and-forth, and forces ${operator.name} into the loop when a thread is going long.

## Examples

### Drafting a fresh email

User: "Send a thank-you to alice@example.com for her review of the SOFT proposal."

Gandalf creates `/sandbox/.hermes/outbox/pending/2026-06-18T14-32-00-thanks-alice-SOFT.json`:
```json
{
  "to": "alice@example.com",
  "subject": "Thanks for your SOFT proposal review",
  "body": "Alice,\n\nThanks for taking the time to review the SOFT proposal. Your feedback on the timeline was particularly helpful.\n\n— ${operator.name}",
  "reason": "User asked Gandalf to send a thank-you note in response to Alice's review of the SOFT proposal. Single-recipient, low-stakes, no attachments."
}
```
Replies to user: "Drafted to alice@example.com — queued for your approval in Slack."

### Replying to an incoming email

When responding to a thread, include `thread_id` so Gmail groups the reply correctly. Get the thread ID from the incoming message's metadata (`gmail search` returns it).

```json
{
  "to": "bob@example.com",
  "subject": "Re: meeting Thursday",
  "body": "...",
  "reason": "Bob asked if Thursday 10am works; ${operator.name}'s calendar shows that slot is open.",
  "thread_id": "abc123xyz"
}
```
