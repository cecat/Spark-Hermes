# 40 — vLLM host bridge

The vLLM container lives on the `nim_net` Docker bridge at `172.18.0.2:8000`. The `gandalf` sandbox lives on a different bridge (`openshell-docker`, 172.19.0.0/16) and can only reach the host on `172.19.0.1` (the bridge gateway). These two systemd-user units bridge the gap so OpenShell's `host.openshell.internal` resolution points at vLLM.

If your vLLM is on a different IP or port, edit the units before installing.

## Install

```
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

If you rebuild the vLLM container and its IP changes:
1. `docker inspect vllm-qwen3-coder-next --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`
2. Edit both `.service` files' `ExecStart` line to point at the new IP.
3. `systemctl --user daemon-reload && systemctl --user restart gandalf-vllm-bridge*.service`

If you switch to a different model on a different port, also update the `inference.base_url` field in `~/.hermes/config.yaml` (port 8000) and the `vllm.container_port` field. Then `bash ../../ops/set-inference.sh`.
