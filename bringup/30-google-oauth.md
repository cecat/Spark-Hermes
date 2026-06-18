# 30 — Google OAuth (via `gog`)

The Hermes-bundled `setup.py --auth-url` flow is broken on multi-account browsers — Google's risk system silently rejects the consent and the browser hangs forever with no error. Use `gog` instead. Works first try.

This step takes ~10 min and is mostly browser clicks.

## Prereqs

- `gog` installed (`command -v gog` returns a path). See `00-prereqs.md`.
- Google Cloud project created, OAuth consent screen **Published** (not in Testing — see "Why publish" below).
- Desktop-app OAuth client created. Download the `client_secret.json` — you'll need its `client_id` and `client_secret` values.

## Setup `gog` for the new project

Drop an unwrapped credentials file (just `{client_id, client_secret}`, no `installed:` wrapper):

```
mkdir -p ~/.config/gogcli
cat > ~/.config/gogcli/credentials-gandalf.json <<'EOF'
{
  "client_id": "YOUR_CLIENT_ID.apps.googleusercontent.com",
  "client_secret": "YOUR_CLIENT_SECRET"
}
EOF
chmod 600 ~/.config/gogcli/credentials-gandalf.json
```

(You should already have `~/.config/gogcli/.gog_pw` and `~/.config/gogcli/config.json` from a previous gog use. If not, see the OpenClaw tutorial's GOG-Integration doc.)

## Run the OAuth dance

```
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog auth add YOUR_AGENT_EMAIL@gmail.com --client gandalf \
  --services gmail.send,gmail,contacts,drive,sheets,docs,calendar \
  --manual --force-consent
```

It prints a URL. Open in any browser, sign in as the agent account, click through "Advanced → Continue (unsafe)" past the unverified-app warning, click Allow. The browser will fail to load `127.0.0.1:<port>/oauth2/callback?...` — **that's expected.** Copy the entire URL from the address bar and paste back at the gog prompt.

## Convert to Hermes' format and install in the sandbox

```
# Export the refresh token
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog auth tokens export YOUR_AGENT_EMAIL@gmail.com --client gandalf \
  --out /tmp/gog-token-export.json

# Build the authorized_user-format token
python3 - <<'PYEOF'
import json
gog = json.load(open('/tmp/gog-token-export.json'))
cs = json.load(open('YOUR_PATH/client_secret.json'))['installed']
token = {
  "type": "authorized_user",
  "client_id": cs['client_id'],
  "client_secret": cs['client_secret'],
  "refresh_token": gog['refresh_token'],
  "scopes": gog['scopes'],
  "token_uri": "https://oauth2.googleapis.com/token",
}
json.dump(token, open('/tmp/google_token.json','w'), indent=2)
import os; os.chmod('/tmp/google_token.json', 0o600)
PYEOF

# Push token + client secret into the sandbox
openshell sandbox upload gandalf /tmp/google_token.json /sandbox/.hermes/google_token.json
openshell sandbox upload gandalf YOUR_PATH/client_secret.json /sandbox/.hermes/google_client_secret.json

# Clean up host scratch
rm /tmp/gog-token-export.json /tmp/google_token.json
```

## Verify

```
docker exec -u sandbox -e HERMES_HOME=/sandbox/.hermes -e PYTHONPATH=/sandbox/.hermes/pylibs \
  $(docker ps --format '{{.Names}}' | grep '^openshell-gandalf-' | head -1) \
  /opt/hermes/.venv/bin/python /opt/hermes/skills/productivity/google-workspace/scripts/setup.py --check
```

Expect: `AUTHENTICATED: Token valid at /sandbox/.hermes/google_token.json` (possibly with "missing scopes" warnings — see below).

## Scope notes

`gog`'s `--services` aliases:
- `gmail` → `gmail.modify, gmail.settings.basic, gmail.settings.sharing` (read + label changes, NOT send)
- `gmail.send` → adds `gmail.send`
- `contacts` → `contacts, contacts.other.readonly, directory.readonly`
- `drive`, `sheets`, `docs`, `calendar` → full scope each

Hermes' built-in `setup.py --check` complains about "missing scopes" `gmail.readonly`, `contacts.readonly` etc. — these are superseded by the broader scopes gog requested. Ignore. Real functionality test: `gmail search`, `drive search`.

## Why publish, not Testing-mode + test users

Testing-mode tokens expire every 7 days. Publishing makes refresh tokens long-lived. The "unverified app" warning is harmless for personal-use apps; click Advanced → Continue once and you're done.

If you must use Testing mode: add every account that will authorize as a test user (https://console.cloud.google.com/auth/audience). The project owner is NOT automatically a test user; this caught us during bringup.

## Why this took 5 hours the first time

Documented at length in `../runlog/RUNLOG-2026-06-17-bringup.md`. Short version: Hermes' `setup.py` flow uses PKCE + `localhost:1` redirect; Safari with multiple Google accounts signed in sends consent submissions under the wrong `authuser=N` index, Google silently rejects, the browser spinner never stops. `gog` uses an ephemeral local port and a single-account flow that doesn't trip the same risk-system path.
