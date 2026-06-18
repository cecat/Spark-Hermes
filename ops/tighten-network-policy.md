# Tighten the sandbox's network policy

The OpenShell 0.0.44 default policy for the `gandalf` sandbox does **not** deny-by-default on general egress. Phase H of the initial bringup (see `../runlog/HANDOFF-2026-06-18.md`) confirmed the sandbox can reach:

- Arbitrary internet hosts (`curl https://httpbin.org/get` → HTTP 200)
- The Tailscale-bound OpenClaw gateway (`100.120.99.52:18789` → HTTP 200)
- Hosts on the local LAN (`10.0.5.x`)
- The host's SSH port (TCP connects; SSH auth itself still holds)

This is materially weaker than the plan assumed. **Credential isolation is fine** — real tokens never enter the sandbox. But network isolation needs help.

## Recommended fix: host-side iptables rules

Mirror what `~/code/spark-ai/` already does for the OpenClaw 172.18 bridge, applied to gandalf's `openshell-docker` bridge (`br-a89074d4fc78`, subnet `172.19.0.0/16`).

### Rules to add

Replace `172.19.0.0/16` with whatever `docker network inspect openshell-docker` reports as the subnet (it could change if the bridge is recreated).

```
# Allow inbound from the bridge to the host (gateway IP 172.19.0.1) — needed
# for the vLLM socat bridge and the Hermes gateway proxy.
sudo iptables -I DOCKER-USER -i br-a89074d4fc78 -d 172.19.0.1 -j ACCEPT

# DENY all Tailscale CGNAT
sudo iptables -I DOCKER-USER -i br-a89074d4fc78 -d 100.64.0.0/10 -j DROP

# DENY local LAN (adjust to your LAN)
sudo iptables -I DOCKER-USER -i br-a89074d4fc78 -d 10.0.0.0/8 -j DROP
sudo iptables -I DOCKER-USER -i br-a89074d4fc78 -d 192.168.0.0/16 -j DROP
sudo iptables -I DOCKER-USER -i br-a89074d4fc78 -d 172.16.0.0/12 ! -d 172.19.0.0/16 -j DROP

# DENY host SSH
sudo iptables -I DOCKER-USER -i br-a89074d4fc78 -p tcp --dport 22 -j DROP
```

### Persist across reboot

Either use `netfilter-persistent` (`sudo apt install iptables-persistent && sudo netfilter-persistent save`) or write a systemd-system unit that re-applies them at boot.

### Verify

```
docker exec -u sandbox $(docker ps --format '{{.Names}}' | grep '^openshell-gandalf-' | head -1) \
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 3 http://100.120.99.52:18789/
# Expect: HTTP 000 (connection refused / timeout)
```

## What this does NOT block

- Internet hosts that OpenShell's L7 proxy permits via the active network policies (oauth2.googleapis.com, etc.). Those still go through, as intended.
- Anything OpenShell handles itself (DNS via the bridge gateway, inference routing).

The iptables rules act as a backstop for egress paths OpenShell's L7 policy doesn't cover.

## Alternative: wait for OpenShell to fix it

OpenShell 0.0.44 is alpha. Future versions may enforce deny-by-default natively, at which point these iptables rules become redundant. Re-test after every OpenShell upgrade.
