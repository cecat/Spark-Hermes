# Follow-ups / backlog

Deferred items that aren't blocking current work. Check this off as they're done.

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
