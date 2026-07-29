# 45 — FALDA host bridge

The self-hosted FALDA memory service binds `127.0.0.1:8077` on the host (no auth
— loopback is its isolation boundary; see `spark-fabric`). The `gandalf` sandbox
lives on the `openshell-docker` bridge (172.19.0.0/16) and can only reach the
host on `172.19.0.1` (the bridge gateway), which `host.openshell.internal`
resolves to. This socat unit bridges the gap — same pattern as `40-vllm-bridge`,
but FALDA needs only ONE unit (it already binds host loopback, so there is no
second host-facing bridge to add).

This is the substrate half of phase 5a. The other half is the egress policy
`bringup/50-openshell-policies/falda-local-egress.yaml`.

## Install

```
cp ./gandalf-falda-bridge-openshell.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gandalf-falda-bridge-openshell.service
sudo loginctl enable-linger catlett   # so the unit survives logout
```

## Verify

```
ss -tlnp | grep '172.19.0.1:8077'
# Expect ONE LISTEN line: 172.19.0.1:8077 (socat)

# End-to-end, from the sandbox's TRACKED egress context (not a bare docker exec —
# see the note below):
nemohermes gandalf exec -- /usr/bin/curl -s http://host.openshell.internal:8077/healthz
# Expect: {"ok":true,"tiers":[...],"pools":true}
```

## Testing gotcha — how NOT to verify

The Hermes gateway forces all egress through the OpenShell L7 proxy
(`10.200.0.1:3128`), which enforces the egress policy per calling principal.
Two misleading test paths, both discovered 2026-07-28:

- **Bare `docker exec ... curl http://host.openshell.internal:8077/...`** returns
  200 even with NO policy — a fresh exec shell has none of the gateway's proxy
  env vars, so it bypasses enforcement entirely. Proves the socat bridge works,
  proves NOTHING about the policy.
- **`docker exec ... curl -x http://10.200.0.1:3128 ...`** returns 403
  `policy_denied` even WITH a correct policy — the exec'd curl isn't part of the
  gateway's tracked process tree, so the proxy won't recognize it as a policy
  principal. (vLLM, which is known-working for the real agent, 403s the same way
  through this path.)

Use `nemohermes gandalf exec` — it runs in the tracked context the proxy honors.
That's the only faithful reproduction of the agent's own egress.

## If FALDA moves

FALDA is pinned to host `127.0.0.1:8077` by `spark-fabric`'s
`services/falda/falda.env`. If that port ever changes, edit `ExecStart` here and
the `port:` in `falda-local-egress.yaml`, then
`systemctl --user restart gandalf-falda-bridge-openshell.service` and re-apply
the policy.
