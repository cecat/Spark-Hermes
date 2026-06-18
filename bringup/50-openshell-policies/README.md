# 50 — OpenShell network policies

Custom OpenShell egress presets for hosts the default policies don't cover.

## Apply both

```
nemohermes gandalf policy-add --from-file ./google-workspace-egress.yaml --yes
nemohermes gandalf policy-add --from-file ./managed-inference-widen.yaml --yes
```

Or use `bash ../../ops/apply-policies.sh` which applies every YAML in this directory.

## What each does

| File | Why |
|---|---|
| [`google-workspace-egress.yaml`](google-workspace-egress.yaml) | Permits egress to Gmail/Drive/Calendar/Docs/Sheets/People/OAuth-refresh APIs. Required for the google-workspace skill to function. |
| [`managed-inference-widen.yaml`](managed-inference-widen.yaml) | Widens the default `managed_inference` policy's path list so Hermes' Ollama-style and bare-path requests are allowed. **Currently unused in the running config** (we use the `vllm-local` provider via the built-in `local-inference` preset instead) — kept for a future Argo retry. See `runlog/HANDOFF-2026-06-18.md` for why. |

## Adding more

Drop a new `<preset-name>.yaml` in this directory following the schema in either of the above. Each preset has a unique `preset.name` and one or more `network_policies.<key>.endpoints` entries. Then re-run `apply-policies.sh`.

The built-in presets (`brew`, `github`, `npm`, `pypi`, `huggingface`, `slack`, `local-inference`, etc.) come from NemoClaw's blueprint — apply those via `nemohermes gandalf policy-add <name> --yes` (no `--from-file`).
