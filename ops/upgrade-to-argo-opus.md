# Upgrade inference from vLLM Qwen → Argo Claude Opus 4.7

Tried twice (Phase D, and again on 2026-06-18 evening). Both times the in-sandbox
OPA enforcer kept denying `POST /api/show` and `POST /chat/completions` on
`inference.local` even after `openshell policy set --wait` confirmed the wider
policy was loaded with matching hash.

This appears to be an OpenShell 0.0.44 defect: live policy updates apply to
the gateway-visible policy (which `nemohermes gandalf status` shows) but the
sandbox-internal enforcer caches the baked-at-image-build policy.

## The proper fix

Bake the wider policy into the sandbox image at build time, then rebuild.

### Steps

1. **Edit the in-repo Hermes policy template** to widen `managed_inference`:
   ```
   nano ~/gandalf-bringup/nemoclaw-src/agents/hermes/policy-additions.yaml
   ```
   In the `managed_inference` block, replace the narrow rules with:
   ```yaml
   rules:
     - allow: { method: GET, path: "/**" }
     - allow: { method: POST, path: "/**" }
     - allow: { method: PUT, path: "/**" }
     - allow: { method: DELETE, path: "/**" }
   ```
   And widen the `binaries:` list to include all hermes venv paths:
   ```yaml
   binaries:
     - { path: /usr/local/bin/hermes }
     - { path: /opt/hermes/.venv/bin/hermes }
     - { path: /opt/hermes/.venv/bin/python }
     - { path: /opt/hermes/.venv/bin/python3 }
     - { path: /opt/hermes/.venv/bin/python3.13 }
     - { path: /usr/local/bin/python3 }
     - { path: /usr/bin/python3 }
   ```

2. **Verify the Argo host bridge is up:**
   ```
   systemctl --user status gandalf-argo-bridge.service
   curl http://172.19.0.1:44497/v1/models | head -c 200
   ```
   If missing, install it the same shape as the vLLM bridges in
   `bringup/40-vllm-bridge/`.

3. **Update `~/.hermes/config.yaml` to point at Argo:**
   ```yaml
   inference:
     provider_name: compatible-anthropic-endpoint
     provider_type: anthropic
     model: claudeopus47
     base_url: http://host.openshell.internal:44497
     credential_env: COMPATIBLE_ANTHROPIC_API_KEY
     credential_value: catlett
   ```
   The `compatible-anthropic-endpoint` provider should already exist; if not,
   `bash ops/set-inference.sh` will create it.

4. **Rebuild the sandbox** so the widened `policy-additions.yaml` gets baked in:
   ```
   export PATH="$HOME/.local/bin:$PATH"
   export COMPATIBLE_ANTHROPIC_API_KEY=catlett
   export OPENAI_API_KEY=local        # vLLM fallback still configured
   nemohermes gandalf snapshot create --name pre-argo-upgrade
   yes y | nemohermes gandalf rebuild --yes
   ```
   Takes ~5-10 min. State (memories, skills, outbox) is preserved via the
   automatic state-backup-and-restore in the rebuild flow.

5. **Set the inference route** to claudeopus47:
   ```
   bash ops/set-inference.sh
   ```

6. **Smoke-test:**
   ```
   curl -sS -X POST http://127.0.0.1:8642/v1/chat/completions \
     -H 'Content-Type: application/json' \
     -d '{"model":"hermes-agent","messages":[{"role":"user","content":"reply with exactly OPUS"}],"max_tokens":5}'
   ```
   Should return `"content": "OPUS"` and `"model": "claudeopus47"` somewhere
   in the response.

## Rollback if Argo still fails

Same as the upgrade in reverse. Update `~/.hermes/config.yaml` `inference:`
back to vllm-local block, `bash ops/set-inference.sh`, and the system is
back to vLLM Qwen with zero data loss. The widened `policy-additions.yaml`
edit you made is benign — wider policy on a model that doesn't hit the
denied paths is a no-op.

## Why this is worth doing

vLLM Qwen3-Coder-Next-FP8 (30B) is significantly weaker than Claude Opus 4.7
at instruction-following. Concretely seen during bringup:
- Hallucinates email addresses despite explicit "don't invent addresses" rules
- Hallucinates network errors ("Gmail API unreachable") when the real network
  is fine — refuses to retry or use the correct tool path
- Over-explains and under-acts when prompts say "do X exactly"

Opus 4.7 dramatically reduces these failure modes. The trade-off is the
alpha-stack policy-cache defect documented above, which is structural
(not a model issue).
