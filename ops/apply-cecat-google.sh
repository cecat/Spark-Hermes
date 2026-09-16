#!/usr/bin/env bash
# Push cecat's Google OAuth credentials into her OpenShell sandbox.
#
# Direct analogue of the credential step in ops/post-rebuild.sh (lines 77 and
# 86), which is Gandalf's proven mechanism: the OpenShell sandboxes have NO bind
# mounts, so the credential is injected into the container's WRITABLE LAYER with
# `openshell sandbox upload`. Same verb, same shape; only the agent, the plane
# and the destination paths differ.
#
# Idempotent: re-running overwrites the two credential files and nothing else.
#
# ── Why this does NOT restart the gateway ────────────────────────────────────
#
# Unlike ops/apply-cecat-slack.sh and ops/apply-cecat-telegram.sh, this script
# changes no openclaw.json key. cecat's Google clients (gmail-api.py,
# contacts-api.py) open and read the token file on every single invocation, so a
# freshly uploaded file is picked up by the next `exec:` with no restart. Do not
# add one.
#
# ── Why the destination paths are what they are ──────────────────────────────
#
# Both scripts resolve their credentials as:
#     token: $GSUITE_MCP_TOKEN_PATH       else $HOME/.local/share/gsuite-mcp/token.json
#     creds: $GSUITE_MCP_CREDENTIALS_PATH else $HOME/.config/gsuite-mcp/credentials.json
# (gmail-api.py:25-28, contacts-api.py:19-22). Uploading to the HOME-relative
# DEFAULTS means no env var has to be injected and openclaw.json is not touched
# at all. HOME inside the sandbox is /sandbox — the same home the OpenClaw
# gateway runs under, which is why its config lives at /sandbox/.openclaw/.
#
# On the LEGACY stack these same two files were bind-mounted to /tmp/gsuite-*.json
# with GSUITE_MCP_*_PATH env vars pointing at them. That indirection existed only
# to dodge a mount collision with gog's directory mounts. There are no mounts
# here, so the defaults are used instead and the env vars are unnecessary.
#
# ── Rebuild survival ─────────────────────────────────────────────────────────
#
# The writable layer is WIPED on rebuild (ops/post-rebuild.sh:126), so this
# script IS the rebuild hook — re-run it after any cecat rebuild, exactly as
# post-rebuild.sh re-runs the upload for Gandalf.
#
# A refreshed token does NOT need syncing back to the host. The durable half of
# the credential is `refresh_token`, which the host copy already holds and which
# Google does not rotate for installed-app clients. The scripts mint a new
# `access_token` from it on demand (gmail-api.py:_refresh) and write it back
# inside the container; losing that on rebuild costs one refresh round-trip, not
# an OAuth re-auth. If the refresh token itself is ever revoked, re-run the host
# browser dance (Spark-OpenClaw/cecat/scripts/reauth.py) and then this script.
#
# ── Egress is a SEPARATE prerequisite, not done here ─────────────────────────
#
# Same split as ops/apply-cecat-telegram.sh. cecat reaches Google as
# /usr/bin/curl (her scripts shell out to curl; the L7 proxy resolves the peer
# binary of whoever opens the socket), so bringup/50-openshell-policies/
# cecat-egress.yaml must already be on her sandbox or every call is denied:
#   bash ops/nmc.sh cecat policy add --from-file bringup/50-openshell-policies/cecat-egress.yaml --yes
#
# Gandalf's google-workspace-egress.yaml does NOT cover her — it lists Python
# paths only, with no curl entry. Do not apply his preset to her, and do not run
# ops/apply-policies.sh, which is hardcoded to gandalf.
#
# Run: bash ops/apply-cecat-google.sh
set -eu

AGENT=cecat
PORT=8090

TOKEN_HOST="$HOME/.local/share/gsuite-mcp/token.json"
CREDS_HOST="$HOME/.config/gsuite-mcp/credentials.json"

TOKEN_DEST=/sandbox/.local/share/gsuite-mcp/token.json
CREDS_DEST=/sandbox/.config/gsuite-mcp/credentials.json

# ── HOME is /root in this sandbox, NOT /sandbox ─────────────────────────────
#
# Verified 2026-09-03 by observation, after this script's first live run failed:
# the process runs as uid 998 (`sandbox`) but inherits HOME=/root, a directory
# that user cannot read.
#
# gmail-api.py:24-28 resolves its credential paths as
#   TOKEN_PATH = $GSUITE_MCP_TOKEN_PATH  else  $HOME/.local/share/gsuite-mcp/token.json
# so with HOME=/root it looks in /root/... and dies on open(). Uploading to
# /sandbox/... alone is not enough — the file has to be where the script looks.
#
# Mirroring into $HOME/... rather than exporting the two env vars, because the
# env-var route only works where the caller remembers to set them. Her runbooks
# invoke `python3 .../gmail-api.py` directly, 24+ call sites, and a new runbook
# would silently omit them. Same reasoning as the XDG_CONFIG_HOME decision in
# apply-luoji-google.sh: put the file where the tool looks, do not make every
# caller compensate.
#
# Both destinations are written; either path then resolves.
SBX_HOME=$(docker exec -u sandbox "$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)" sh -c 'echo $HOME' 2>/dev/null | tr -d '\r')
SBX_HOME=${SBX_HOME:-/root}
TOKEN_DEST2="$SBX_HOME/.local/share/gsuite-mcp/token.json"
CREDS_DEST2="$SBX_HOME/.config/gsuite-mcp/credentials.json"

OPENSHELL_101="$HOME/gandalf-bringup/openshell-0.0.101/bin/openshell"

[ -f "$TOKEN_HOST" ] || { echo "missing $TOKEN_HOST — re-auth first: python3 ~/code/Spark-OpenClaw/cecat/scripts/reauth.py" >&2; exit 1; }
[ -f "$CREDS_HOST" ] || { echo "missing $CREDS_HOST — download the OAuth desktop-app client from Google Cloud Console" >&2; exit 1; }
[ -x "$OPENSHELL_101" ] || { echo "missing the 0.0.101 openshell binary: $OPENSHELL_101" >&2; exit 1; }

CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
[ -n "$CON" ] || { echo "no running sandbox for $AGENT — start it: bash ops/agent-planes.sh start" >&2; exit 1; }

# Talk to cecat's OWN control plane. Never inherits an ambient gateway
# selection, and never uses the global v0.0.55 `nemoclaw`, which would relaunch
# a plaintext gateway on this port using Gandalf's database. Same guard rails as
# the osh() helper in ops/agent-planes.sh and the exec line in ops/nmc.sh.
osh() {
    env -u OPENSHELL_GATEWAY -u OPENSHELL_GATEWAY_ENDPOINT \
        NEMOCLAW_GATEWAY_PORT="$PORT" \
        "$OPENSHELL_101" -g "nemoclaw-${PORT}" "$@"
}

# ── The OpenShell proxy CA ──────────────────────────────────────────────────
#
# ADDED 2026-09-03. The original version of this script omitted this step, on
# the reasoning that "curl uses the system trust store, which already trusts the
# proxy CA." That is true ONLY IF something previously installed the proxy root
# into this container — and nothing had. Gandalf's mechanism is certifi /
# HTTPLIB2_CA_CERTS, which are read by named Python libraries and do nothing
# whatsoever for curl. Charlie caught the asymmetry by asking why the CA step
# existed for luoji and not for cecat.
#
# Without this, every Google call from her sandbox fails the TLS handshake with
# "certificate signed by unknown authority" — and because her scripts shell out
# to curl, the failure surfaces as a nonzero exit with no useful message.
#
# Same mechanism as ops/apply-luoji-google.sh section 1: append to the OS trust
# store, never replace it. update-ca-certificates regenerates
# /etc/ssl/certs/ca-certificates.crt from the distro roots plus
# /usr/local/share/ca-certificates, so nothing is deleted.
CA_SRC=/etc/openshell-tls/ca-bundle.pem
CA_DEST=/usr/local/share/ca-certificates/openshell-proxy.crt
SYS_BUNDLE=/etc/ssl/certs/ca-certificates.crt

echo "--- installing the OpenShell proxy CA into the container OS trust store ---"

docker exec -u root "$CON" test -f "$CA_SRC" || {
    echo "the proxy CA is not at $CA_SRC in this container." >&2
    echo "Without a trusted proxy root, curl fails every Google TLS handshake" >&2
    echo "with 'certificate signed by unknown authority'." >&2
    exit 1
}

docker exec -u root "$CON" mkdir -p "$(dirname "$CA_DEST")"
docker exec -u root "$CON" cp "$CA_SRC" "$CA_DEST"
docker exec -u root "$CON" chmod 644 "$CA_DEST"

if docker exec -u root "$CON" sh -c 'command -v update-ca-certificates >/dev/null 2>&1'; then
    docker exec -u root "$CON" update-ca-certificates 2>&1 | sed 's/^/    /'
else
    echo "    update-ca-certificates absent; appending to $SYS_BUNDLE directly"
    docker exec -u root -e CA_DEST="$CA_DEST" -e SYS_BUNDLE="$SYS_BUNDLE" "$CON" sh -c '
        if grep -q "OpenShell proxy CA (apply-cecat-google.sh)" "$SYS_BUNDLE" 2>/dev/null; then
            echo "already present; no-op"
        else
            { echo ""; echo "# OpenShell proxy CA (apply-cecat-google.sh)"; cat "$CA_DEST"; } >> "$SYS_BUNDLE"
            echo "appended"
        fi'
fi

# Verify at the layer that owns the thing: the bundle curl actually reads.
docker exec -u root -e SYS_BUNDLE="$SYS_BUNDLE" "$CON" sh -c \
    'printf "    certs in the system bundle: "; grep -c "BEGIN CERTIFICATE" "$SYS_BUNDLE"'

# CURL_CA_BUNDLE or SSL_CERT_FILE in the sandbox env would REPLACE the system
# bundle for curl, making the install above inert. Warn rather than fight it.
if docker exec -u sandbox "$CON" sh -c '[ -n "${CURL_CA_BUNDLE:-}${SSL_CERT_FILE:-}" ]' 2>/dev/null; then
    echo "    WARNING: CURL_CA_BUNDLE or SSL_CERT_FILE is set in the sandbox env."
    echo "             Either REPLACES the system bundle for curl, so the trust"
    echo "             store install above will not take effect."
fi

# `upload` will not create missing parents. Create them as `sandbox`: a
# directory created by root here is unwritable by the gateway's own user, which
# is what broke `memory index` on 2026-08-21.
docker exec -u sandbox "$CON" mkdir -p "$(dirname "$TOKEN_DEST")" "$(dirname "$CREDS_DEST")"

# --no-git-ignore: `upload` applies .gitignore filtering by default, which is
# how 64 of cecat's files were silently dropped during the earlier migration
# (see the header of ops/apply-agent-workspace.sh). These are two explicit
# single files outside any repo, so disabling the filter can only make the
# upload deterministic — it cannot pull in anything extra.
echo "--- uploading Google OAuth credentials into the writable layer ---"
osh sandbox upload "$AGENT" "$TOKEN_HOST" "$TOKEN_DEST" --no-git-ignore >/dev/null
echo "  token.json       -> $TOKEN_DEST"
osh sandbox upload "$AGENT" "$CREDS_HOST" "$CREDS_DEST" --no-git-ignore >/dev/null
echo "  credentials.json -> $CREDS_DEST"

# Upload does not carry the host mode across. The token is a bearer credential;
# the client secret is read-only to the scripts.
docker exec -u root "$CON" chown sandbox:sandbox "$TOKEN_DEST" "$CREDS_DEST"
docker exec -u root "$CON" chmod 600 "$TOKEN_DEST"
docker exec -u root "$CON" chmod 400 "$CREDS_DEST"

# ── Point the scripts at the credentials via a wrapper ──────────────────────
#
# ABANDONED APPROACH, recorded so nobody retries it: mirroring the credentials
# into $HOME (/root) does not work. **/root is mode 700, owned by root**, so the
# sandbox user (uid 998) cannot traverse into it regardless of what the files
# inside are chmod'd to. The mirror "succeeded" and produced files no one could
# open — the identical traceback, which is what made it look like a no-op.
#
# So the env-var route is the correct one after all. gmail-api.py:24-28 honours
# GSUITE_MCP_TOKEN_PATH / GSUITE_MCP_CREDENTIALS_PATH ahead of $HOME. The
# earlier objection — "every caller has to remember to set them" — is answered
# by putting them in a WRAPPER rather than asking callers to export anything.
#
# The wrapper takes the name the runbooks already invoke, and the real script
# moves aside. 24+ call sites keep working untouched.
GMAIL_REAL=/sandbox/.openclaw/workspace/scripts/gmail-api.real.py
GMAIL_SHIM=/sandbox/.openclaw/workspace/scripts/gmail-api.py
CONTACTS_REAL=/sandbox/.openclaw/workspace/scripts/contacts-api.real.py
CONTACTS_SHIM=/sandbox/.openclaw/workspace/scripts/contacts-api.py

echo "--- installing credential-path wrappers ---"
for pair in "$GMAIL_SHIM:$GMAIL_REAL" "$CONTACTS_SHIM:$CONTACTS_REAL"; do
    SHIM="${pair%%:*}"; REAL="${pair##*:}"
    docker exec -u sandbox "$CON" test -f "$SHIM" || { echo "  skip: $SHIM not present"; continue; }
    # Idempotent: only move the real script aside the first time. A second run
    # must not overwrite the real script with the wrapper.
    if ! docker exec -u sandbox "$CON" test -f "$REAL"; then
        docker exec -u sandbox "$CON" cp "$SHIM" "$REAL"
    fi
    docker exec -u sandbox -i -e REAL="$REAL" -e TOKEN_DEST="$TOKEN_DEST" -e CREDS_DEST="$CREDS_DEST" \
        "$CON" sh -c 'cat > '"$SHIM" <<EOF
#!/usr/bin/env python3
# Installed by Spark-Hermes ops/apply-cecat-google.sh. Do not edit in place —
# a rebuild wipes it. Edit the generator.
#
# HOME is /root in this sandbox and /root is mode 700, so the sandbox user
# cannot read anything under it. The real script defaults its credential paths
# to \$HOME/... and therefore cannot find them. This wrapper pins the paths to
# where the deploy actually put the files, then hands off.
import os, runpy, sys
os.environ.setdefault("GSUITE_MCP_TOKEN_PATH", "$TOKEN_DEST")
os.environ.setdefault("GSUITE_MCP_CREDENTIALS_PATH", "$CREDS_DEST")
runpy.run_path("$REAL", run_name="__main__")
EOF
    docker exec -u sandbox "$CON" chmod 755 "$SHIM"
    echo "  $SHIM -> pins credential paths, execs $(basename "$REAL")"
done

# Verify shape only. Field NAMES and expiry, never values — Spark-Hermes is a
# PUBLIC repo and this output gets pasted into reports.
echo "--- verifying (names and modes only, no values) ---"
docker exec -u sandbox -e TOKEN_DEST="$TOKEN_DEST" -e CREDS_DEST="$CREDS_DEST" \
    "$CON" python3 - <<'PY'
import json, os, stat

for label, path in (("token", os.environ["TOKEN_DEST"]),
                    ("credentials", os.environ["CREDS_DEST"])):
    st = os.stat(path)
    with open(path) as f:
        d = json.load(f)
    keys = sorted(d)
    if label == "credentials":
        keys = [f"installed.{k}" for k in sorted(d.get("installed", {}))] or keys
    print(f"  {label}: mode {stat.filemode(st.st_mode)}  {st.st_size} bytes")
    print(f"    fields: {', '.join(keys)}")
    if label == "token":
        print(f"    has refresh_token: {'refresh_token' in d}")
        print(f"    access_token expiry: {d.get('expiry', '(absent)')}")
PY

echo ""
echo "No gateway restart needed — the scripts read these files per invocation."
echo "Egress prerequisite (apply separately if 'cecat-egress' is not already ●):"
echo "  bash ops/nmc.sh cecat policy add --from-file bringup/50-openshell-policies/cecat-egress.yaml --yes"
