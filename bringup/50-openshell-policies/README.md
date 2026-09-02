# 50 — OpenShell network policies

Custom OpenShell egress presets for hosts the default policies don't cover.

## Apply both

```
nemohermes gandalf policy-add --from-file ./google-workspace-egress.yaml --yes
nemohermes gandalf policy-add --from-file ./managed-inference-widen.yaml --yes
```

Or use `bash ../../ops/apply-policies.sh gandalf --shared`. The agent argument is
mandatory. A file named `<agent>-*.yaml` belongs to that agent and is only applied
to that agent's plane; every other file is a shared capability preset, applied only
with `--shared`. Gandalf's own set is entirely unprefixed, hence `gandalf --shared`.

## What each does

| File | Why |
|---|---|
| [`google-workspace-egress.yaml`](google-workspace-egress.yaml) | Permits egress to Gmail/Drive/Calendar/Docs/Sheets/People/OAuth-refresh APIs. Required for the google-workspace skill to function. |
| [`managed-inference-widen.yaml`](managed-inference-widen.yaml) | Widens the default `managed_inference` policy's path list so Hermes' Ollama-style and bare-path requests are allowed. **Currently unused in the running config** (we use the `vllm-local` provider via the built-in `local-inference` preset instead) — kept for a future Argo retry. See `runlog/HANDOFF-2026-06-18.md` for why. |

## Adding more

Drop a new `<preset-name>.yaml` in this directory following the schema in either of the above. Each preset has a unique `preset.name` and one or more `network_policies.<key>.endpoints` entries. Then re-run `apply-policies.sh <agent> [--shared]` for the plane it belongs to. Name it `<agent>-*.yaml` if it is specific to one agent, so it can never be pushed to another.

The built-in presets (`brew`, `github`, `npm`, `pypi`, `huggingface`, `slack`, `local-inference`, etc.) come from NemoClaw's blueprint — apply those via `nemohermes gandalf policy-add <name> --yes` (no `--from-file`).
