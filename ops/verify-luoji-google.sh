#!/usr/bin/env bash
# READ-ONLY proof that luoji's Google access works end to end.
#
#   bash ops/verify-luoji-google.sh
#
# Makes ONE read-only Google API call from inside luoji's sandbox. Sends no
# email, creates nothing, modifies nothing, deletes nothing. Exercises the whole
# chain at once: OS trust store (CA), gog wrapper, keyring passphrase, file
# keyring, OAuth refresh, and the L7 egress preset.
#
# WHY: credentials being present is NOT proof. That inference has been wrong
# twice on this box. A capability is YES only on an observed
# request-and-response. See patterns/dispatching-workers.md.
set -u

CON=$(docker ps --format '{{.Names}}' | grep '^openshell-default--luoji-' | head -1)
[ -n "$CON" ] || { echo "no running sandbox for luoji" >&2; exit 1; }

# Six tokens are in the keyring and no default is set, so gog requires an
# explicit --account. luoji's own Google identity is tpc26agent@gmail.com (the
# account his legacy daily Drive upload ran as). Override with GOG_ACCOUNT=... .
ACCOUNT="${GOG_ACCOUNT:-tpc26agent@gmail.com}"

echo "--- environment gog actually sees ---"
docker exec -u sandbox -i "$CON" sh <<'SH' 2>&1 | sed 's/^/  /'
echo "HOME              = ${HOME:-(unset)}"
echo "user              = $(id -un) (uid $(id -u))"
echo "GOG_ACCOUNT       = ${GOG_ACCOUNT:-(unset)}"
echo "XDG_CONFIG_HOME   = ${XDG_CONFIG_HOME:-(unset)}"
echo "config gog reads  = ${XDG_CONFIG_HOME:-$HOME/.config}/gogcli"
echo "config we wrote   = /sandbox/.config/gogcli"
if [ "${XDG_CONFIG_HOME:-$HOME/.config}/gogcli" != "/sandbox/.config/gogcli" ]; then
  echo "  *** MISMATCH — gog will not find the uploaded credentials ***"
fi
SH

echo
echo "--- which accounts does the sandbox keyring hold? ---"
docker exec -u sandbox -i "$CON" sh <<'SH' 2>&1 | sed 's/^/  /'
ls /sandbox/.config/gogcli/keyring 2>/dev/null | sed 's/^token://'
SH

echo
echo "--- READ-ONLY: gog contacts list (account: $ACCOUNT) ---"
# XDG_CONFIG_HOME is passed explicitly because HOME is /root in this sandbox
# while the process runs as uid 998 (sandbox), which cannot read /root. The
# installed wrapper sets this too; passing it here means the check still works
# if the wrapper predates that fix.
docker exec -u sandbox -i -e ACCOUNT="$ACCOUNT" -e XDG_CONFIG_HOME=/sandbox/.config \
    "$CON" sh <<'SH' 2>&1 | sed 's/^/  /'
cd /sandbox
timeout 90 gog contacts list --account "$ACCOUNT" --limit 3 2>&1 | head -25
echo "---exit:$?---"
SH

echo
echo "--- egress decisions logged during that call ---"
docker logs --tail 2000 -t "$CON" 2>&1 \
  | grep -iE 'googleapis|DENIED' | tail -8 | sed 's/^/  /'

echo
echo "HOW TO READ THIS"
echo "  Contact names or an empty-but-valid result = YES, the cell is proven."
echo "  'certificate signed by unknown authority'  = CA missing from trust store."
echo "  'DENIED' on a googleapis host              = egress preset gap; the"
echo "                                               denied path names the rule."
echo "  'keyring' / 'passphrase' error             = .gog_pw or wrapper problem."
