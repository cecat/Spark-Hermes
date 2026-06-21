# Runlog 2026-06-21 — Tavily-as-single-host egress pivot

## What changed

OpenShell egress went from a 150-host curated allowlist to a thin "transport
gate" pattern: arbitrary-URL web access for Gandalf flows through
`api.tavily.com`, the one allowlisted host.

## Where the safety actually comes from (and where it doesn't)

This is the important nuance: **the safety story is different for direct
egress vs. Tavily-routed fetches.**

- **Direct egress** (the ~15 hosts still in `web-readonly-egress.yaml`
  + the dedicated presets — Google APIs, GitHub, PyPI, HuggingFace,
  NPM, Slack, Wikipedia, ANL/TPC26 work hosts): the sandbox resolves
  these hostnames via the host's resolver, which is **NextDNS profile
  "Spark"**. Malware / phishing / porn / gambling / piracy categories
  return NXDOMAIN before the connection ever leaves the host. NextDNS
  IS the destination-level safety layer for these.

- **Tavily-routed fetches** (`api.tavily.com` is the only OpenShell
  egress host; Gandalf POSTs the target URL to Tavily; Tavily's
  servers do the actual fetch): the resolution and fetch happen on
  Tavily's infrastructure, **not** from the Spark host. **NextDNS
  never sees those queries.** It cannot filter them.

  For Tavily-routed URLs, the safety layer is:
    - Tavily's own URL-fetch service (which sanitizes content, strips
      JS, returns markdown — so even a malicious target page can't
      execute code in Gandalf's context)
    - Tavily's domain trust signals (they refuse known-malicious
      domains at their layer)
    - Gandalf's outbox + approval pattern (any action Gandalf takes
      based on fetched content — sending an email, editing a sheet —
      still needs a human ✅)

So the accurate "what protects what" matrix:

  | Layer      | Direct-egress hosts | Tavily-fetched URLs |
  |------------|---------------------|---------------------|
  | NextDNS    | ✓ blocks at DNS     | ✗ doesn't see them  |
  | OpenShell  | ✓ host allowlist    | ✓ only api.tavily.com|
  | Tavily     | n/a                 | ✓ content sanitization|
  | Outbox     | applies to actions  | applies to actions  |

The earlier framing — "NextDNS handles destination-level safety" —
was true only for the direct-egress column. Do not generalize it.

Commits: `ec6e828` (egress pivot), and the follow-up that restored work hosts
(`www.anl.gov`, `tpc26.org`, `trillionparameters.org` and their subdomain
wildcards — these were accidentally dropped in the slim-down).

## Crash loop incident — and the root cause

Yesterday (2026-06-20) I'd run an empirical test: submit a preset with
`host: "*"` to see if OpenShell's policy validator would accept it. It
hard-rejected with *"host wildcard '*' matches all hosts; use specific
patterns like '*.example.com'"* — useful confirmation, but the failed
submission persisted in `~/.local/state/nemoclaw/openshell-docker-gateway/openshell.db`
as a `sandbox_policy` row with `status='failed'`.

Three things went wrong from there:

1. Every subsequent `nemohermes sandbox policy add --from-file ...` call
   computed a diff against state that *still included* the failed
   `allow_all_https`, so the recomposed policy ALSO contained it and ALSO
   failed validation. Versions 9, 10, 11 all marked Failed for the same reason.
2. Today, after editing `/sandbox/.hermes/.env` and recomputing the
   NemoClaw integrity hash, the sandbox container restarted itself. On
   boot the OpenShell supervisor fetched its policy via gRPC, the supervisor
   tried to load the latest failed version, validation rejected it, the
   supervisor exited 1, Docker (restart-policy `unless-stopped`) brought
   it right back up, and the cycle repeated every ~30s.
3. The active (last-known-good) v8 was sitting unused because the
   supervisor wouldn't fall back to it.

**Fix** (surgical, single SQL):

```sql
DELETE FROM objects
WHERE scope='c34590f5-34f8-481b-a1e3-a11a84ec11a6'
  AND object_type='sandbox_policy'
  AND status='failed';
```

After the delete: container came up clean on v8, then I applied v9 (slimmed
`web-readonly-egress`) and v10 (new `tavily-egress`) successfully. Both
loaded. v11 was the work-host restore.

**Lesson for next person**: NemoClaw's policy diff computer trusts whatever
sandbox_policy rows exist for the scope. Don't experimentally submit
broken presets — `openshell policy list <name>` will show them as Failed
but the diff machinery doesn't filter on status. If you must, plan to
clean up immediately:

```sql
DELETE FROM objects WHERE scope='<sandbox-uuid>'
  AND object_type='sandbox_policy' AND status='failed';
```

(The cleaner alternative would be a `--dry-run` flag in `nemohermes
sandbox policy add` for experiments, but I didn't notice one in `--help`.)

## urllib vs httpx vs curl — what egress policy actually sees

While verifying the new tavily preset I wrote three different proof
scripts. Results were not identical, and the discrepancy is worth
documenting so the next person doesn't waste an hour.

### urllib (Python stdlib `urllib.request.urlopen`) — FAILED

```python
ctx = ssl.create_default_context(cafile="/etc/openshell-tls/ca-bundle.pem")
with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
    ...
```

Even with `HTTPS_PROXY=http://10.200.0.1:3128` set in the script's env
and the OpenShell CA bundle as the TLS cafile, this got
**`Tunnel connection failed: 403 Forbidden`** at the proxy CONNECT step.

OCSF showed the denial as: `endpoint api.tavily.com:443 not in policy 'brew';
... not in policy 'web_readonly'` — i.e. the OPA engine tried every preset
EXCEPT `tavily`, even though `tavily` had `api.tavily.com` and the actor
binary `/opt/hermes/.venv/bin/python` was in `tavily`'s `binaries:`.

Hypothesis (unconfirmed): urllib's HTTPS-via-proxy path uses `HTTPSHandler` →
`HTTPConnection._tunnel()`, which issues a literal `CONNECT api.tavily.com:443
HTTP/1.1` to the proxy. OPA's HTTP layer sees the CONNECT BEFORE TLS is
established, so it doesn't know which preset to use for the inner request
yet, and falls through every preset's `endpoints:` checking host-only
matchers. tavily's preset has `protocol: rest` which (we think) requires
the inner-request method/path/host to be available — but on CONNECT, only
the host is known, so the matcher misses.

### `httpx.post()` (the NATIVE Hermes path) — WORKED

Imported `plugins.web.tavily.provider.TavilyWebSearchProvider` directly
(same module the gateway loads), called `.search()` and `.extract()`.
Both returned real results — Wikipedia hit for Charlie, 11K extract of
`blog.zorinaq.com`. httpx behaves like curl, not like urllib.

So the Tavily-egress pivot is real end-to-end: when Hermes' native
`web_search` / `web_extract` tools fire, they hit the same code path
and work.

### `curl -x http://10.200.0.1:3128 -X POST https://api.tavily.com/...` — WORKED

This was the script the Tavily-egress proof originally ran. Result:
clean 11,442-character extract from `blog.zorinaq.com`. Same proxy, same
CA bundle, same destination, same auth — and the OPA decision was
Allowed under preset `tavily`.

Why curl works where urllib didn't: best guess is that curl's CONNECT
request format or header order matches what OPA's L7 layer expects in
a way urllib's doesn't. Could also be the difference between
`Proxy-Connection: Keep-Alive` (curl) vs urllib's default. Did not
chase to root cause.

### What it means

- The native `web_search` / `web_extract` path is fine — httpx works.
  Verified by importing the real `plugins.web.tavily.provider.TavilyWebSearchProvider`
  module the gateway loads and calling `.search()` and `.extract()` directly:
  both returned real content.

- For ad-hoc scripts (sandbox-side `inject-openshell-ca.sh`,
  `outbox-send.py`, etc.) that go through the L7 proxy, the safe bet is
  **`curl` or `httpx`, NOT `urllib`**. urllib's CONNECT-tunnel path
  doesn't carry the right shape for OPA's L7 policy resolution against a
  `protocol: rest` endpoint, and the request gets denied as "not in any
  policy". This isn't a curl-vs-Python thing — it's specifically a
  urllib-vs-the-rest thing.

- If a future skill or script trips over this, the fix is one-line:
  swap `urllib.request.urlopen` for `httpx.get`/`httpx.post` (already
  in the venv).

## Final state

- Active OpenShell policy: v11, hash 65246ef1233e, Loaded.
- Total host entries: 48.
- `api.tavily.com` present (tavily preset).
- `allow_all_https` absent everywhere: active policy, NemoClaw's
  `sandboxes.json` customPolicies, openshell.db payload search.
- Work hosts restored: `www.anl.gov`, `*.anl.gov`, `tpc26.org`,
  `*.tpc26.org`, `trillionparameters.org`, `*.trillionparameters.org`.
- Container: running, restartCount=19, no die events since the
  crash-loop fix at 07:34 CDT.
- Gateway: pid 197, both api_server and slack platforms connected.
- Heartbeat: ok=true, no failures.
- All four production cron jobs healthy.

## Related

- Commit `ec6e828` — the pivot itself.
- Commit `4c13508` — earlier `/hermes sethome` notice suppression
  (same pattern of editing `.env` + recomputing NemoClaw integrity hash).
- Memory: `~/.claude/projects/-home-catlett-code-Spark-Hermes/memory/`
  has `openshell-egress-peer-resolution.md` documenting an adjacent
  policy-resolution gotcha.
