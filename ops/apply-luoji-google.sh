#!/usr/bin/env bash
# Make Google work for luoji inside his OpenShell sandbox, via the `gog` Go CLI.
#
# Modelled on ops/apply-luoji-slack.sh (container discovery, plane discipline)
# and on the credential step of ops/post-rebuild.sh lines 77 and 86, which is
# Gandalf's proven transport: OpenShell sandboxes have NO bind mounts, so a
# credential is injected into the container's WRITABLE LAYER with
# `openshell sandbox upload`. Same verb, same shape.
#
# Idempotent: re-running overwrites the binary, the CA and the credential files
# and nothing else. Creates only; removes nothing.
#
# ── THIS SCRIPT IS THE REBUILD HOOK ─────────────────────────────────────────
#
# The writable layer is WIPED on rebuild (ops/post-rebuild.sh:126). Everything
# this script installs — the gog binary, the CA in the OS trust store, the
# keyring, the client credentials, the keyring password — lives in that layer
# and vanishes. Re-run this script after ANY luoji rebuild, exactly as
# post-rebuild.sh re-runs the upload for Gandalf. There is no other hook; if
# this is not run, `gog` is simply absent again.
#
# ── Why this does NOT restart the gateway ───────────────────────────────────
#
# Unlike ops/apply-luoji-slack.sh and ops/apply-luoji-telegram.sh, this script
# changes no openclaw.json key. gog is a short-lived process spawned per `exec:`
# call and reads its credentials from disk every invocation, so a freshly
# uploaded file is picked up by the next call with no restart. Do not add one.
#
# ── THE HARD PART: the CA. Read this before changing anything TLS-related. ──
#
# All sandbox egress is MITM'd by the OpenShell L7 proxy at 10.200.0.1:3128,
# which re-signs every server certificate with `CN=OpenShell Sandbox CA`. The
# proxy's root is already present in the container at
# /etc/openshell-tls/ca-bundle.pem (ops/_lib.sh:66-81, sandbox-scripts/
# outbox-send.py:96-111).
#
# Gandalf's two mechanisms are BOTH INERT FOR GO and must not be copied:
#   - HTTPLIB2_CA_CERTS / REQUESTS_CA_BUNDLE  are read by specific Python
#     libraries. Go has never heard of them.
#   - sandbox-scripts/inject-openshell-ca.sh appends the root to CERTIFI's
#     bundle. certifi is a Python package. Go does not read it.
#
# Go's crypto/x509 loadSystemRoots (root_unix.go) reads, in order:
#   1. $SSL_CERT_FILE          — if set, REPLACES the file list entirely
#   2. $SSL_CERT_DIR           — if set, REPLACES the directory list
#   3. a built-in list of OS bundle paths, /etc/ssl/certs/ca-certificates.crt
#      first on Debian/Ubuntu
#
# So there are two possible fixes. We use the OS trust store, not the env var:
#
#   REJECTED — export SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem.
#     It works, but it REPLACES the system roots rather than adding to them, so
#     it depends on that bundle also containing the public web roots. More
#     importantly it only applies where the variable is exported, and luoji
#     calls gog from inside `exec: python3 <<EOF` blocks with an explicitly
#     constructed env (RUNBOOK_HEALTH_REPORT.md:144 builds `env = {**os.environ,
#     ...}`) — a per-call env var is exactly the kind of thing a new runbook
#     forgets. That failure mode is silent until it is a TLS error at 13:09Z.
#
#   CHOSEN — install the root into the OS trust store, system-wide:
#     copy to /usr/local/share/ca-certificates/openshell-proxy.crt and run
#     update-ca-certificates, which APPENDS it to
#     /etc/ssl/certs/ca-certificates.crt. Every Go, node, curl and python
#     process in the container then trusts it with no env var, and the public
#     roots are preserved. This is the conventional path and it is what any
#     future Go tool will also need.
#
#   The system bundle is appended to, never replaced: update-ca-certificates
#     regenerates ca-certificates.crt from /usr/share/ca-certificates (the
#     distro roots) plus /usr/local/share/ca-certificates (ours). Nothing is
#     deleted. If update-ca-certificates is absent from the image, the script
#     appends to the bundle directly, guarded by a marker so it cannot double-
#     append.
#
#   SSL_CERT_FILE is deliberately NOT exported anywhere by this script. If it is
#     set in the environment by something else, it OVERRIDES the trust store we
#     just populated and this whole step becomes a no-op — the script warns if
#     it sees that.
#
# ── Credential transport ────────────────────────────────────────────────────
#
# gog stores refresh tokens in a 99designs/keyring FILE backend: one encrypted
# file per token under $XDG_CONFIG_HOME/gogcli/keyring (internal/config/
# paths.go:40-47, AppName="gogcli"), unlocked by a passphrase read from
# $GOG_KEYRING_PASSWORD (internal/secrets/store.go:50, 197). With no TTY and no
# password set, gog fails with "no TTY available for keyring file backend
# password prompt" — so the passphrase MUST be in the env of the calling
# process. That is why the legacy stack's wrapper existed.
#
# On the legacy container these came from rw bind mounts of ~/.config/gogcli and
# ~/.local/share/keyrings. OpenShell has no mounts, so each file is uploaded
# into the writable layer instead. HOME inside the sandbox is /sandbox, so the
# XDG default resolves to /sandbox/.config/gogcli — uploading there means no env
# var has to be injected for the PATHS. Only the passphrase needs an env var.
#
# ~/.local/share/keyrings/gogcli.keyring is NOT uploaded. That is the
# SecretService (gnome-keyring) database, a different backend; the file backend
# reads the per-token files under ~/.config/gogcli/keyring. The legacy container
# mounted both because it mounted whole directories, not because both were used
# — config.json pins keyring_backend=file.
#
# ── The wrapper ─────────────────────────────────────────────────────────────
#
# ~/.local/bin/gog-wrap on the host is STALE AND BROKEN — it execs
# /usr/local/bin/gog-real, which does not exist outside the legacy container's
# mount namespace. It is not copied and nothing here is modelled on it. This
# script installs a fresh wrapper at /usr/local/bin/gog which exports
# GOG_KEYRING_PASSWORD from the uploaded .gog_pw and execs the real binary at
# /usr/local/lib/gog/gog.
#
# Why a wrapper at all, rather than requiring every caller to set the env var:
# runbooks invoke bare `gog` (RUNBOOK_SLACK_POST.md:62) and set the password by
# hand in python (RUNBOOK_HEALTH_REPORT.md:139-144). The wrapper makes the bare
# invocation work and makes the hand-set one redundant-but-harmless. It reads
# the passphrase from a 0400 file at call time and never logs it.
#
# NOTE for the egress preset: the peer binary the L7 proxy sees is the REAL Go
# binary, since the wrapper `exec`s it. bringup/50-openshell-policies/
# luoji-google-egress.yaml therefore lists the real path. Keep GOG_REAL below
# and the `binaries:` list in that file in sync.
#
# ── Egress is a SEPARATE prerequisite, not done here ────────────────────────
#
# Same split as ops/apply-luoji-telegram.sh. Without the preset every call is
# refused at the L7 proxy:
#   bash ops/nmc.sh luoji policy add --from-file bringup/50-openshell-policies/luoji-google-egress.yaml --yes
#
# Gandalf's google-workspace-egress.yaml does NOT cover luoji (Python-only
# binaries, and it allows the Gmail send route). Do not apply his preset to him,
# and do not run ops/apply-policies.sh, which is hardcoded to gandalf.
#
# Run: bash ops/apply-luoji-google.sh
set -eu

AGENT=luoji
PORT=8091

# ── Host sources ────────────────────────────────────────────────────────────
GOG_BIN_HOST=/usr/local/bin/gog
GOGCLI_HOST="$HOME/.config/gogcli"
KEYRING_HOST="$GOGCLI_HOST/keyring"
GOG_PW_HOST="$GOGCLI_HOST/.gog_pw"
GOG_CONFIG_HOST="$GOGCLI_HOST/config.json"

# ── Sandbox destinations. HOME inside the sandbox is /sandbox, so
#    /sandbox/.config/gogcli is gog's XDG default — no env var needed. ───────
GOG_REAL=/usr/local/lib/gog/gog          # real Go binary; what the proxy sees
GOG_SHIM=/usr/local/bin/gog              # wrapper on PATH; execs GOG_REAL
GOGCLI_DEST=/sandbox/.config/gogcli
KEYRING_DEST="$GOGCLI_DEST/keyring"
GOG_PW_DEST="$GOGCLI_DEST/.gog_pw"

CA_SRC=/etc/openshell-tls/ca-bundle.pem
CA_DEST=/usr/local/share/ca-certificates/openshell-proxy.crt
SYS_BUNDLE=/etc/ssl/certs/ca-certificates.crt

OPENSHELL_101="$HOME/gandalf-bringup/openshell-0.0.101/bin/openshell"

# ── Preflight ───────────────────────────────────────────────────────────────
[ -x "$GOG_BIN_HOST" ]  || { echo "missing the gog binary: $GOG_BIN_HOST" >&2; exit 1; }
[ -d "$KEYRING_HOST" ]  || { echo "missing the gog keyring dir: $KEYRING_HOST — run 'gog auth add <email>' on the host first" >&2; exit 1; }
[ -f "$GOG_PW_HOST" ]   || { echo "missing $GOG_PW_HOST — the file-backend passphrase; without it gog cannot open the keyring headlessly" >&2; exit 1; }
[ -f "$GOG_CONFIG_HOST" ] || { echo "missing $GOG_CONFIG_HOST" >&2; exit 1; }
[ -x "$OPENSHELL_101" ] || { echo "missing the 0.0.101 openshell binary: $OPENSHELL_101" >&2; exit 1; }

# The host binary is a dynamically linked aarch64 ELF against glibc. The sandbox
# image is glibc/aarch64 too, so it runs as-is; a musl image would need a static
# rebuild (CGO_ENABLED=0) from ~/code/gogcli instead. Checked here rather than
# discovered as an exec-format error at 13:09Z.
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) echo "host is $(uname -m); the gog binary at $GOG_BIN_HOST is aarch64 and will not run in the sandbox" >&2; exit 1 ;;
esac

CON=$(docker ps --format '{{.Names}}' | grep "^openshell-default--${AGENT}-" | head -1)
[ -n "$CON" ] || { echo "no running sandbox for $AGENT — start it: bash ops/agent-planes.sh start" >&2; exit 1; }

# Talk to luoji's OWN control plane. Never inherits an ambient gateway
# selection, and never uses the global v0.0.55 `nemoclaw`, which would relaunch
# a plaintext gateway on this port using Gandalf's database. Same guard rails as
# the osh() helper in ops/agent-planes.sh and the exec line in ops/nmc.sh.
osh() {
    env -u OPENSHELL_GATEWAY -u OPENSHELL_GATEWAY_ENDPOINT \
        NEMOCLAW_GATEWAY_PORT="$PORT" \
        "$OPENSHELL_101" -g "nemoclaw-${PORT}" "$@"
}

# `upload` applies .gitignore filtering by default, which is how 64 of cecat's
# files were silently dropped during the earlier migration (see the header of
# ops/apply-agent-workspace.sh). Every upload here is an explicit single file
# outside any repo, so --no-git-ignore can only make it deterministic.
upload() { osh sandbox upload "$AGENT" "$1" "$2" --no-git-ignore >/dev/null; }

# ── 1. CA into the OS trust store ───────────────────────────────────────────
# THE crux for Go. See the long block comment above for why the env-var route
# was rejected. Appends; never replaces the distro roots.
echo "--- installing the OpenShell proxy CA into the container OS trust store ---"

docker exec -u root "$CON" test -f "$CA_SRC" || {
    echo "the proxy CA is not at $CA_SRC in this container." >&2
    echo "Locate it before continuing — without a trusted proxy root, gog fails" >&2
    echo "every TLS handshake with x509: certificate signed by unknown authority." >&2
    exit 1
}

docker exec -u root "$CON" mkdir -p "$(dirname "$CA_DEST")"
docker exec -u root "$CON" cp "$CA_SRC" "$CA_DEST"
docker exec -u root "$CON" chmod 644 "$CA_DEST"

if docker exec -u root "$CON" sh -c 'command -v update-ca-certificates >/dev/null 2>&1'; then
    docker exec -u root "$CON" update-ca-certificates 2>&1 | sed 's/^/    /'
else
    # No ca-certificates package in the image. Append straight to the bundle,
    # guarded by a marker so a re-run cannot double-append. Additive only.
    echo "    update-ca-certificates absent; appending to $SYS_BUNDLE directly"
    docker exec -u root -e CA_DEST="$CA_DEST" -e SYS_BUNDLE="$SYS_BUNDLE" "$CON" sh -c '
        if grep -q "OpenShell proxy CA (apply-luoji-google.sh)" "$SYS_BUNDLE" 2>/dev/null; then
            echo "already present; no-op"
        else
            { echo ""; echo "# OpenShell proxy CA (apply-luoji-google.sh)"; cat "$CA_DEST"; } >> "$SYS_BUNDLE"
            echo "appended"
        fi'
fi

# Verify at the layer that owns the thing: the bundle Go will actually read.
# A count that did not grow means update-ca-certificates silently no-op'd.
docker exec -u root -e SYS_BUNDLE="$SYS_BUNDLE" "$CON" sh -c \
    'printf "    certs in the system bundle: "; grep -c "BEGIN CERTIFICATE" "$SYS_BUNDLE"'

# If SSL_CERT_FILE is set in the sandbox environment it REPLACES the file list
# in Go's loadSystemRoots, making everything above inert. Warn loudly.
if docker exec -u sandbox "$CON" sh -c '[ -n "${SSL_CERT_FILE:-}" ]' 2>/dev/null; then
    echo "    WARNING: SSL_CERT_FILE is set in the sandbox env. Go's crypto/x509"
    echo "             treats it as a REPLACEMENT for the system bundle, so the"
    echo "             trust store install above will not take effect for gog."
fi

# ── 2. The gog binary ───────────────────────────────────────────────────────
echo "--- installing gog ---"

# Upload to a sandbox-writable staging path first: `openshell sandbox upload`
# runs as the sandbox user and cannot write under /usr/local.
STAGE=/sandbox/.cache/gog-install
docker exec -u sandbox "$CON" mkdir -p "$STAGE"
upload "$GOG_BIN_HOST" "$STAGE/gog"

docker exec -u root "$CON" mkdir -p "$(dirname "$GOG_REAL")"
docker exec -u root "$CON" cp "$STAGE/gog" "$GOG_REAL"
docker exec -u root "$CON" chmod 755 "$GOG_REAL"
echo "    real binary -> $GOG_REAL"

# The wrapper. Reads the passphrase at call time from a 0400 file so it is never
# baked into the script, an image layer, or a process listing. `exec` means the
# peer binary the L7 proxy resolves is GOG_REAL, which is what the egress preset
# lists. Modelled on nothing — ~/.local/bin/gog-wrap is stale and broken.
docker exec -u root -i -e GOG_REAL="$GOG_REAL" -e GOG_PW_DEST="$GOG_PW_DEST" -e GOG_SHIM="$GOG_SHIM" \
    "$CON" sh -c 'cat > "$GOG_SHIM"' <<EOF
#!/bin/sh
# Installed by Spark-Hermes ops/apply-luoji-google.sh. Do not edit in place —
# a rebuild wipes it; change the generator instead.
#
# gog's keyring file backend needs its passphrase in the environment: with no
# TTY it errors "no TTY available for keyring file backend password prompt"
# (gogcli internal/secrets/store.go). Callers invoke bare \`gog\`, so the
# wrapper supplies it rather than every runbook remembering to.
GOG_KEYRING_BACKEND=file
export GOG_KEYRING_BACKEND
if [ -r "$GOG_PW_DEST" ]; then
    GOG_KEYRING_PASSWORD=\$(cat "$GOG_PW_DEST")
    export GOG_KEYRING_PASSWORD
fi
# HOME is /root in this sandbox even though the process runs as uid 998
# (sandbox), which cannot read /root. Verified 2026-09-03: gog resolved its
# config to /root/.config/gogcli and failed with "permission denied" on a path
# it could never read. gog uses XDG (\$XDG_CONFIG_HOME, else \$HOME/.config), so
# pin XDG_CONFIG_HOME to where the credentials were actually uploaded rather
# than relying on HOME being correct.
#
# An earlier version of this script asserted "HOME inside the sandbox is
# /sandbox" on the strength of a runbook line. It is not. Observe, do not infer.
XDG_CONFIG_HOME=/sandbox/.config
export XDG_CONFIG_HOME
exec "$GOG_REAL" "\$@"
EOF
docker exec -u root "$CON" chmod 755 "$GOG_SHIM"
echo "    wrapper     -> $GOG_SHIM (on PATH; execs the real binary)"

docker exec -u sandbox "$CON" rm -rf "$STAGE"

# ── 3. Credentials ──────────────────────────────────────────────────────────
# Same transport as ops/post-rebuild.sh:77,86 — upload into the writable layer.
echo "--- uploading gog credentials into the writable layer ---"

# `upload` will not create missing parents. Create them as `sandbox`: a
# directory created by root here is unwritable by the agent's own user, which is
# what broke `memory index` on 2026-08-21.
docker exec -u sandbox "$CON" mkdir -p "$KEYRING_DEST"

upload "$GOG_CONFIG_HOST" "$GOGCLI_DEST/config.json"
echo "    config.json  -> $GOGCLI_DEST/config.json"

upload "$GOG_PW_HOST" "$GOG_PW_DEST"
echo "    .gog_pw      -> $GOG_PW_DEST"

# One encrypted file per token. Uploaded individually rather than as a directory
# so the set is explicit and nothing unexpected rides along.
for f in "$KEYRING_HOST"/*; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    upload "$f" "$KEYRING_DEST/$bn"
    echo "    keyring item -> $KEYRING_DEST/$bn"
done

# The client OAuth secrets. Only the ones gog resolves by name
# (internal/config/paths.go:67-83): credentials.json is the "default" client,
# credentials-<name>.json is a named one. Every luoji call site passes
# `--client default`, so credentials.json is the load-bearing file; the others
# are uploaded when present because `-a <account>` can select them.
for f in "$GOGCLI_HOST"/credentials.json "$GOGCLI_HOST"/credentials-*.json; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    upload "$f" "$GOGCLI_DEST/$bn"
    echo "    client creds -> $GOGCLI_DEST/$bn"
done

# Upload does not carry the host mode across. These are bearer credentials.
docker exec -u root -e GOGCLI_DEST="$GOGCLI_DEST" "$CON" sh -c '
    chown -R sandbox:sandbox "$GOGCLI_DEST"
    chmod 700 "$GOGCLI_DEST" "$GOGCLI_DEST/keyring"
    find "$GOGCLI_DEST" -type f -exec chmod 600 {} +
    chmod 400 "$GOGCLI_DEST/.gog_pw"'

# ── 4. Verify shape only ────────────────────────────────────────────────────
# Names, modes and counts. NEVER values — Spark-Hermes is a PUBLIC repo and this
# output gets pasted into reports. No Google operation is performed here; that
# is a separate, supervised step.
echo "--- verifying (names, modes and counts only, no values) ---"
docker exec -u sandbox -e GOGCLI_DEST="$GOGCLI_DEST" -e GOG_SHIM="$GOG_SHIM" -e GOG_REAL="$GOG_REAL" \
    -e SYS_BUNDLE="$SYS_BUNDLE" "$CON" sh -c '
    printf "    gog on PATH        : "; command -v gog || echo "NOT FOUND"
    printf "    real binary        : "; [ -x "$GOG_REAL" ] && echo "present, executable" || echo "MISSING"
    printf "    keyring items      : "; ls -1 "$GOGCLI_DEST/keyring" 2>/dev/null | wc -l
    printf "    .gog_pw            : "; [ -r "$GOGCLI_DEST/.gog_pw" ] && stat -c "%A %s bytes" "$GOGCLI_DEST/.gog_pw" || echo "MISSING"
    printf "    client cred files  : "; ls -1 "$GOGCLI_DEST"/credentials*.json 2>/dev/null | wc -l
    printf "    system CA bundle   : "; grep -c "BEGIN CERTIFICATE" "$SYS_BUNDLE"'

echo ""
echo "No gateway restart needed — gog is spawned per exec: call and reads these files each time."
echo ""
echo "Egress prerequisite (apply separately if 'luoji-google-egress' is not already ●):"
echo "  bash ops/nmc.sh luoji policy add --from-file bringup/50-openshell-policies/luoji-google-egress.yaml --yes"
echo ""
echo "Gmail SEND is NOT permitted by that preset, by design. Sending stays"
echo "host-side behind the approval gate in shared/scripts/cron/send-email.sh."
