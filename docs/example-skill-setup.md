# Example: asking Gandalf to set up a recurring task

A worked example of how to prompt Gandalf so that he correctly sets up a
recurring (cron-driven) skill on his own, with a human approval gate
before the schedule is created.

## Three principles behind the prompt shape

1. **Separate "set up the cron" from "what the cron should do."** Don't
   ask Gandalf to do the work AND schedule it in the same message. Ask
   him to (a) draft the future-prompt, (b) show it for approval, (c)
   only then call `hermes cron create`. Gives you a checkpoint before a
   recurring job is born.

2. **Make the future-prompt context-free.** Whatever wording you give
   Gandalf, the version that runs on the schedule sees only what's in
   the cron-prompt arg, not your DM history. So the future-prompt must
   be self-contained: who he is, what to do, what to deliver, how to
   format, what to skip.

3. **Make outputs verifiable, not just plausible.** "Report news" invites
   hallucinated headlines. Narrow the format spec until fabrication
   becomes hard ("each item must include a clickable URL the user can
   open" + "if you can't find a URL, drop the item").

## The prompt (paste this into your Slack DM with Gandalf)

```
Gandalf — set up a new recurring job for me, but DON'T create it yet.

Goal: every Monday at 8am Central, search the web for news about
Charlie Catlett (me) from the past 7 days. Post a single Slack message
to my DM with the results.

Format per item: one bullet, title in bold, then a one-sentence summary,
then the URL on its own line. Skip anything without a real URL. Cap at
the top 5 by recency. If nothing relevant, post exactly one line:
"No new mentions this week."

Use the web search tool (any provider that's working). Do not draft an
email — Slack only, no outbox.

Steps:
  1. Write out the EXACT prompt you would store in the cron job, so
     future-you (no memory of this conversation) can execute it cleanly.
     Include who you are, the task, the format rules, and the
     "no fabrication" rule.
  2. Show me the prompt text + the cron schedule you'd use + the
     `hermes cron create` command you'd run.
  3. WAIT for me to reply ✅ before actually running it.

When I approve, create the job and confirm with `hermes cron list`.
```

## Why each piece is there

| Piece of the prompt | What it buys you |
|---|---|
| "DON'T create it yet" + "WAIT for me to reply ✅" | Approval gate Hermes doesn't enforce on its own — Gandalf can create unbounded crons by default. |
| "Write out the EXACT prompt you would store" | Forces him to surface the future-prompt for your review. That's the artifact that actually runs at 8am every Monday, not your DM. |
| "title in bold + URL on its own line + skip without URL + cap at 5" | Deterministic enough that a future session can follow it; narrow enough that fabricated entries stand out. |
| "Slack only, no outbox" | Prevents him from routing this through the email-drafting skill out of habit. |
| "any provider that's working" | Acknowledges that some web search backends (Brave-free, DDGS, etc.) may rate-limit; lets him fall back. |

## Predictable failure to watch for

Gandalf may translate "8am Central" into the wrong cron expression.
Hermes cron runs in UTC, so:

- CDT (summer): `0 13 * * 1` = 8am Central
- CST (winter): `0 14 * * 1` = 8am Central

If you want a stable-across-DST job, accept the one-hour shift twice a
year or ask him to pick the winter version.

## After the first run

Look at what he posted. If headlines look fabricated, tighten the
prompt ("paste the raw URL from the search tool output, do not
summarize URLs"). Iteration tightens it fast.

## Related

- Web reads beyond the OpenShell `google-workspace-egress` preset
  currently fail — need a broad-egress preset before Gandalf can fetch
  arbitrary URLs. See repo TODO.
- NextDNS is filtering all DNS on the Spark host (profile "Spark",
  id YOUR_NEXTDNS_PROFILE_ID), so even with broad OpenShell egress, malware /
  phishing / parental-control-blocked categories never resolve.
