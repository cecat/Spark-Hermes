---
name: falda-memory
description: "How to use FALDA long-term memory: your private store (tenant gandalf), the cross-agent shared pool (shared-corpus), the falda_share / falda_search tools when they're enabled, and the raw HTTP API as a fallback. Load when you want to recall something from long-term memory, share a fact with the other agent (Luoji), or the memory tools aren't available."
version: 1.0.0
metadata:
  hermes:
    tags: [falda, memory, recall, shared-corpus, cross-agent, luoji]
---

# FALDA long-term memory

FALDA is a tiered long-term memory store (stream → atoms → scenes → core) with
hybrid vector + full-text search, running loopback-only on the host and reachable
from the sandbox at `http://host.openshell.internal:8077`. It is shared substrate:
you (Gandalf) and the other agent (Luoji) each have a private tenant, and there is
one opt-in shared pool.

## The three things you can address

- **Your private memory** — `tenant: gandalf`, no pool. Every one of your
  Telegram/Slack turns is already mirrored here automatically (a host-side shadow
  tap), so your own conversation history is searchable without you doing anything.
- **The cross-agent shared pool** — `tenant: gandalf`, `pool: shared-corpus`.
  Readable AND writable by both you and Luoji. This is the ONLY place memory
  crosses between agents. Nothing lands here unless someone deliberately puts it
  here.
- **Luoji's private memory** — not accessible to you. Cross-agent sharing happens
  ONLY through `shared-corpus`.

## The tools (when enabled)

Depending on the current experiment condition, you may have these tools:

- **`falda_search(query, limit?)`** — search your private memory AND the shared
  pool at once. Returns matching stream turns and atoms with scores. Use it to dig
  for something specific that isn't in your current context.
- **`falda_share(content)`** — deliberately write a fact into `shared-corpus` so
  Luoji can see it. Use this ONLY for things genuinely worth sharing across
  agents — durable facts, decisions, context the other agent would benefit from.
  It is NOT a scratchpad and NOT for every turn; your own turns are already
  captured privately. Curated sharing, not a firehose.

If automatic recall is on, relevant memory is injected into your context before
each turn without any tool call — you may already have what you need.

## Raw HTTP API (fallback when the tools aren't present)

All endpoints are `POST` with a JSON body. `tenant` defaults if omitted; include
`pool` to address the shared pool.

```bash
BASE=http://host.openshell.internal:8077

# Search your private memory
curl -s -X POST $BASE/stream/search -H 'content-type: application/json' \
  -d '{"tenant":"gandalf","query":"deploy process","limit":5}'

# Search the shared pool
curl -s -X POST $BASE/atoms/search -H 'content-type: application/json' \
  -d '{"tenant":"gandalf","pool":"shared-corpus","query":"deploy process","limit":5}'

# Share a fact into the shared pool (visible to Luoji)
curl -s -X POST $BASE/stream/add -H 'content-type: application/json' \
  -d '{"tenant":"gandalf","pool":"shared-corpus","session_id":"gandalf:manual",
       "messages":[{"role":"assistant","content":"The X migration is frozen until Thursday."}]}'

# Read the shared core document (T3), if any
curl -s -X POST $BASE/core/read -H 'content-type: application/json' \
  -d '{"tenant":"gandalf"}'
```

Response shapes: `/stream/search` → `{"messages":[{id,role,content,timestamp,score}]}`;
`/atoms/search` → `{"items":[{id,type,content,...,score}]}`; `/core/read` →
`{"content":"..."}`.

## Notes

- Writes to `shared-corpus` are append-only — re-posting the same content adds a
  new copy. Share deliberately, once.
- If a search returns nothing, it genuinely found nothing for that query — try
  different terms rather than assuming the store is empty.
