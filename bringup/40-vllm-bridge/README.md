# 40 — vLLM host bridge

The vLLM container lives on the `nim_net` Docker bridge. The `gandalf` sandbox lives on a different bridge (`openshell-docker`, 172.19.0.0/16) and can only reach the host on `172.19.0.1` (the bridge gateway). These two systemd-user units bridge the gap so OpenShell's `host.openshell.internal` resolution points at vLLM.

Both units run `ops/vllm-bridge.sh`, which **resolves the container IP with
`docker inspect` at start** rather than pinning it, re-checks every 30s, and
exits if the container moved so `Restart=always` re-resolves. Nothing needs
editing when vLLM's IP changes.

If your vLLM is on a different *port*, or the container is renamed, pass them as
arguments in the unit's `ExecStart`.

## Install

```
chmod +x ~/code/Spark-Hermes/ops/vllm-bridge.sh
cp ./gandalf-vllm-bridge.service             ~/.config/systemd/user/
cp ./gandalf-vllm-bridge-openshell.service   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gandalf-vllm-bridge.service gandalf-vllm-bridge-openshell.service
sudo loginctl enable-linger catlett   # so the units survive your logout
```

## Verify

```
ss -tlnp | grep ':8000'
# Expect TWO LISTEN lines: 127.0.0.1:8000 and 172.19.0.1:8000
curl -sf http://127.0.0.1:8000/v1/models | head -c 100
# Expect JSON with the model id
```

## What if vLLM moves

**Nothing to do — this is handled.** `docker compose down` deletes the container
and `nim_net`, and vLLM only reclaims `172.18.0.2` by luck of container start
order. `~/shutdown.sh` (via `spark-ai/shutdown.sh`) uses `stop`, not `down`,
partly to avoid the move; the deliberate memory-reclaim step in
`spark-ai/README.md` § "Note on vLLM and memory" does a `down` and will move it.

Until 2026-09-01 the units hardcoded `172.18.0.2`, so a move silently pointed
Gandalf's inference at a dead address with nothing on this side verifying it —
the first symptom was Gandalf going quiet. `ops/vllm-bridge.sh` now resolves the
IP at start and exits on a move so systemd re-resolves. The bridge is correct by
construction; there is no manual step.

Deliberately NOT fixed by having `spark-ai/start-all.sh` restart these units on
its own cascade: that reintroduces cross-world coupling between the OpenClaw and
Hermes stacks, which the ops consolidation is removing.

To confirm what a bridge is currently pointed at:
`journalctl --user -u gandalf-vllm-bridge.service -n 5`

If you switch to a different model on a different port, also update the `inference.base_url` field in `~/.hermes/config.yaml` (port 8000) and the `vllm.container_port` field. Then `bash ../../ops/set-inference.sh`.
