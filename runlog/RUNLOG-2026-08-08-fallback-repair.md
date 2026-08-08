# RUNLOG 2026-08-08 — OpenClaw fallback repair

**Executed:** TASK-2026-08-08-FINAL-fallback-repair.md
**Outcome:** Fix 1 applied and **proven against a forced failure**. All three gates
passed. Both §2 loose ends resolved. Fix 2 not touched, per instruction.

---

## Gate results

### Gate A2 — PASS
No entry in `agents.list[]` carried a `fallbacks` key. Baseline:

```json
{"defaults": {"primary": "vllm/Qwen/Qwen3-Coder-Next-FP8",
              "fallbacks": ["vllm/Qwen/Qwen3-Coder-Next-FP8"]},
 "agents": [{"id": "luoji", "model": {"primary": "argo/claudeopus47"}},
            {"id": "cecat", "model": {"primary": "argo/claudesonnet46"}}]}
```

### Gate B — PASS, and proven by execution rather than by reading

`/app/dist/agent-scope-CDZXADgT.js`, lines 201-206, printed by line range:

```js
function resolveSelectedModelFallbacksOverride(raw) {
	if (!raw) return;
	if (typeof raw === "string") return resolvePrimaryStringValue(raw) ? [] : void 0;
	if (!Object.hasOwn(raw, "fallbacks")) return Object.hasOwn(raw, "primary") && resolvePrimaryStringValue(raw) ? [] : void 0;
	return Array.isArray(raw.fallbacks) ? raw.fallbacks : void 0;
}
```

Consumer at 269-277:

```js
function resolveEffectiveModelFallbacks(params) {
	const agentFallbacksOverride = resolveAgentModelFallbacksOverride(params.cfg, params.agentId);
	if (!params.hasSessionModelOverride) return agentFallbacksOverride;
	...
```

The task noted this claim had exactly one source (one read by one agent) and said not
to accept it on that basis. So rather than re-read it, I **imported the real module in
the real container and called it**:

```
luoji  (primary, no fallbacks) override = []
noblock(no model block)        override = undefined
luoji  effective fallbacks = []
noblock effective fallbacks = undefined
luoji WITH fallbacks (the fix)  = ["vllm/Q"]
```

Confirms all three propositions: `primary`-without-`fallbacks` → `[]` (explicit empty,
defaults NOT inherited); absent block → `undefined`; and adding the key produces a real
chain. The root cause and the fix are both verified against executing code.

### Gate C — PASS
`VLLM_API_KEY` is absent from the gateway environment, as predicted. A real completion
through `http://nim:8000/v1` sending the literal unresolved string
`Authorization: Bearer VLLM_API_KEY` **succeeded**:

```
{"id":"chatcmpl-...","model":"Qwen/Qwen3-Coder-Next-FP8",
 "choices":[{"message":{"content":"OK! ..."},"finish_reason":"stop"}]}
```

vLLM does not enforce auth, so the unresolved key is harmless. Model id confirmed
exactly `Qwen/Qwen3-Coder-Next-FP8`. The concern that the fallback path might 401 on
first live use is closed.

---

## §2 loose ends

### Loose end 2 — RESOLVED: one incident, not a daily job

144 timeout events occupy lines 69049–97294 of a 105,007-line log. Maximum gap between
consecutive events is **329 lines**; no gap exceeds 500. Timestamps are monotonically
non-decreasing across all 144 (15:29:14 → 15:36:54), which a daily recurrence could not
produce. **Single continuous incident. Nothing runs daily at 15:30.**

### Loose end 1 — RESOLVED: the 792→864 growth was a counting difference, not accrual

The count is **not** accruing. Sampled twice three seconds apart: 864 and 864. The log's
last write was 15:23 against a 15:25 check, and only 7 timeout-matching lines exist
after the final event — all continuation fragments (`Error doing the fallback:` /
`litellm.exceptions.Timeout:`), no new router-ERROR events.

The arithmetic is suggestive: 864 − 792 = **72**, and exactly 72 lines in the log match
the `litellm.llms.openai.common_utils.OpenAIError` variant. The earlier 792 figure most
likely came from a grep that excluded that one variant. Consistent with a counting
difference between passes, not with 12 new events.

This further supports §2: the incident is closed and static.

---

## Change applied

One file: `~/code/spark-ai/apply-config.sh`.
Backup: `apply-config.sh.bak-20260808`.

```diff
@@ -309,6 +309,18 @@
         needed_providers.add(model_str.split("/")[0])
 
+    # --- Validate the global fallback model (same rules as agent models) ---
+    fallback_model_str = defaults_config.get("fallback_model", "").strip()
+    if fallback_model_str:
+        if "/" not in fallback_model_str:
+            print(f"ERROR: defaults.fallback_model must be 'provider/model-id', got: '{fallback_model_str}'")
+            sys.exit(1)
+        fallback_provider = fallback_model_str.split("/")[0]
+        if fallback_provider not in NATIVE_PROVIDERS and fallback_provider not in providers_config:
+            print(f"ERROR: defaults.fallback_model references provider '{fallback_provider}' but it is not defined in config.yaml providers:")
+            sys.exit(1)
+        needed_providers.add(fallback_provider)
+
@@ -436,7 +448,16 @@
         for entry in agents_list:
             if entry["id"] == agent_id:
-                entry["model"] = {"primary": model_str}
+                # An agent model block with no "fallbacks" key is an EXPLICIT empty
+                # override in OpenClaw — it does not inherit agents.defaults.model
+                # .fallbacks. So the fallback must be written per-agent here.
+                model_entry = dict(entry.get("model") or {})
+                model_entry["primary"] = model_str
+                if fallback_model and fallback_model != model_str:
+                    model_entry["fallbacks"] = [fallback_model]
+                else:
+                    model_entry.pop("fallbacks", None)
+                entry["model"] = model_entry
```

`--dry-run` diffed against the live config showed **exactly two additions and nothing
else** — a `fallbacks` array on each of the two agents. No incidental churn. Applied,
gateway restarted, reported healthy.

Resulting live config:

```json
[{"id":"luoji","model":{"primary":"argo/claudeopus47",
                        "fallbacks":["vllm/Qwen/Qwen3-Coder-Next-FP8"]}},
 {"id":"cecat","model":{"primary":"argo/claudesonnet46",
                        "fallbacks":["vllm/Qwen/Qwen3-Coder-Next-FP8"]}}]
```

**Known oddity, left alone per owner decision:** `agents.defaults.model` still has
primary and fallback both set to `vllm/Qwen/Qwen3-Coder-Next-FP8`. The `!=` guard stops
that pathology from reaching any agent. Not changed this session.

---

## Proof — forced failure

Waiting for a natural Argo timeout was withdrawn as a strategy (§2 found zero in the
retained log), so the failure was forced.

**Method.** Copied the live config, set `models.providers.argo.baseUrl` to
`http://172.18.0.1:44499` — a dead port, verified to have zero listeners beforehand,
while port 44497 kept its 3 listeners. `argo-shim` itself was **never touched**; no Duo
re-auth was required. Installed via `docker cp`, restarted the gateway, and ran one
agent turn through the gateway CLI with an isolated `--session-id` and no `--deliver`,
so nothing was sent to any channel.

**Result — decision lines, verbatim:**

```
2026-08-08T20:29:01.447+00:00 [model-fallback/decision] model fallback decision: decision=candidate_failed requested=argo/claudeopus47 candidate=argo/claudeopus47 reason=timeout next=vllm/Qwen/Qwen3-Coder-Next-FP8 detail=fetch failed
2026-08-08T20:29:26.541+00:00 [model-fallback/decision] model fallback decision: decision=candidate_succeeded requested=argo/claudeopus47 candidate=vllm/Qwen/Qwen3-Coder-Next-FP8 reason=unknown next=none
```

`next=vllm/Qwen/Qwen3-Coder-Next-FP8`, replacing `next=none`. The second line shows the
fallback actually **completing**, and the agent returned its expected reply (`PROOF`)
despite Argo being unreachable. This is the first time an OpenClaw request has ever
reached vLLM.

**Revert.** Restored `openclaw.json.bak-20260808-postfix1` via `docker cp`, restarted.
`argo.baseUrl` is back to `http://172.18.0.1:44497`. A full `jq -S` diff against the
post-fix baseline is **identical** — clean revert. A live Argo turn afterwards returned
`ARGOOK`, confirming the normal path works.

---

## Post-state

- `openclaw-gateway` — healthy.
- `vllm-qwen3-coder-next` — Up 4 weeks, never restarted or reconfigured.
- `ollama`, both FALDA distillers, `gandalf-litellm` — all still `active`.
- `argo-shim` — untouched, 3 listeners on 44497.
- Nothing under `~/.falda/data/` touched. `DISTILLER_MODEL` unchanged. LiteLLM
  fallback topology unchanged.

Backups: `~/code/spark-ai/apply-config.sh.bak-20260808`,
`~/openclaw.json.bak-20260808-postfix1`.

---

## Open items (not actioned)

1. **Follow-up carried forward:** LiteLLM `request_timeout: 120` × `num_retries: 2`
   = up to 360 s behind the distiller's 180 s client timeout. Confirmed latent hazard;
   fired twice (`L2 argo error: timed out`, luoji, 2026-08-02). Own work item.
2. **`defaults.model` self-referential fallback** — left in place per owner decision.
3. **Nothing in the task looked wrong to me.** The one instruction I strengthened rather
   than followed literally was Gate B: the task said to print and read it, and I
   executed it instead, because the task itself flagged that a single reading was the
   weakest link in the chain.
