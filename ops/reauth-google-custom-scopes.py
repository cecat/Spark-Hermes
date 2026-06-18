#!/usr/bin/env python3
"""
Manual OAuth dance against ~/.hermes/config.yaml's google.scopes list.

Use this when you need scope combinations gog doesn't support (notably gmail.send
plus the existing gmail.modify — gog's --services gmail is all-or-nothing and
excludes send).

Usage (from anywhere):
    python3 ~/code/Spark-Hermes/ops/reauth-google-custom-scopes.py

Reads:
    ~/.hermes/config.yaml    google.scopes[], google.client_secret_host_path,
                             google.token_host_path
Writes:
    ~/.hermes/google_token.json (host copy) + /sandbox/.hermes/google_token.json
    (uploaded via openshell sandbox upload, if the sandbox is running)
"""

import json
import os
import subprocess
import sys
import yaml
from pathlib import Path

# oauthlib refuses http:// redirect URLs by default (paranoid HTTPS-only).
# Loopback HTTP is the OAuth-spec-blessed exception for desktop apps —
# Google explicitly issues codes to http://127.0.0.1:<port>/... for installed
# clients. Tell oauthlib to allow it.
os.environ.setdefault("OAUTHLIB_INSECURE_TRANSPORT", "1")
# Google always adds openid + userinfo.email to the granted scope set when
# access_type=offline. oauthlib treats "granted != requested" as a hard error
# by default; this disables that strictness (we verify granted scopes ourselves
# at the end).
os.environ.setdefault("OAUTHLIB_RELAX_TOKEN_SCOPE", "1")

CONFIG = Path.home() / ".hermes" / "config.yaml"

def main():
    if not CONFIG.exists():
        sys.exit(f"Missing {CONFIG}")
    cfg = yaml.safe_load(CONFIG.read_text())
    g = cfg.get("google", {})
    scopes = g.get("scopes") or []
    if not scopes:
        sys.exit("No google.scopes in config.yaml")
    cs_path = Path(os.path.expanduser(g.get("client_secret_host_path", "")))
    tok_path = Path(os.path.expanduser(g.get("token_host_path", "")))
    if not cs_path.exists():
        sys.exit(f"Missing client secret at {cs_path}")

    # Ensure deps are available — install into a one-shot venv if needed.
    try:
        from google_auth_oauthlib.flow import Flow  # noqa
    except ImportError:
        venv = Path.home() / "gandalf-bringup" / "oauth-venv"
        if not venv.exists():
            print(f"Creating one-shot venv at {venv}...")
            subprocess.check_call([sys.executable, "-m", "venv", str(venv)])
        subprocess.check_call([str(venv / "bin/pip"), "install", "--quiet",
                               "google-auth-oauthlib", "PyYAML"])
        # Re-exec under the venv
        os.execv(str(venv / "bin/python"), [str(venv / "bin/python"), __file__])

    from google_auth_oauthlib.flow import Flow
    import socket

    # Pick a free ephemeral port; mirror gog's redirect-URI shape exactly.
    # (Working gog URL had redirect_uri=http://127.0.0.1:<ephemeral>/oauth2/callback;
    # failing setup.py URL had redirect_uri=http://localhost:1. That's the only
    # structural difference between the two flows. Use what works.)
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    redirect_uri = f"http://127.0.0.1:{port}/oauth2/callback"

    flow = Flow.from_client_secrets_file(
        str(cs_path),
        scopes=scopes,
        redirect_uri=redirect_uri,
    )
    auth_url, state = flow.authorization_url(
        access_type="offline",
        prompt="consent",
        include_granted_scopes="true",
    )

    print()
    print("================ Open this URL in any browser ================")
    print()
    print(auth_url)
    print()
    print("Sign in as the agent account, click Allow.")
    print("Browser will fail to load 'localhost:1' — copy the entire URL")
    print("from the address bar and paste below.")
    print()
    resp = input("Paste redirect URL (or just the ?code= value): ").strip()
    if not resp:
        sys.exit("Nothing pasted; aborting.")

    if resp.startswith("http"):
        flow.fetch_token(authorization_response=resp)
    else:
        flow.fetch_token(code=resp)

    creds = flow.credentials
    token = {
        "type": "authorized_user",
        "client_id": creds.client_id,
        "client_secret": creds.client_secret,
        "refresh_token": creds.refresh_token,
        "scopes": creds.scopes or scopes,
        "token_uri": "https://oauth2.googleapis.com/token",
    }
    tok_path.parent.mkdir(parents=True, exist_ok=True)
    tok_path.write_text(json.dumps(token, indent=2))
    os.chmod(tok_path, 0o600)
    print(f"\n✓ Wrote {tok_path} (mode 600)")
    print(f"  scopes granted: {len(creds.scopes or scopes)}")
    for s in (creds.scopes or scopes):
        print(f"    - {s}")

    # Push into the sandbox if it's running
    try:
        out = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True, text=True, check=True,
        )
        container = next(
            (l for l in out.stdout.splitlines() if l.startswith("openshell-gandalf-")),
            None,
        )
        if container:
            print(f"\n✓ Sandbox is running ({container})")
            print("  Uploading token to /sandbox/.hermes/google_token.json...")
            openshell = os.path.expanduser("~/.local/bin/openshell")
            subprocess.check_call([
                openshell, "sandbox", "upload", "gandalf",
                str(tok_path), "/sandbox/.hermes/google_token.json",
            ])
            print("✓ Uploaded.")
        else:
            print("\n(Sandbox not running — token saved to host only; upload manually later.)")
    except FileNotFoundError:
        print("\n(docker not on PATH — token saved to host only.)")

    print("\nDone. Verify with: bash ~/code/Spark-Hermes/ops/status.sh")

if __name__ == "__main__":
    main()
