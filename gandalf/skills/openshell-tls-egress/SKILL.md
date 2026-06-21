---
name: openshell-tls-egress
description: "Fix Python TLS failures and map the egress allowlist in OpenShell-managed sandboxes. Run when sheets.googleapis.com / gmail / drive throws 'self-signed certificate in certificate chain', or when curl returns 'CONNECT tunnel failed, response 403'."
version: 1.0.0
metadata:
  hermes:
    tags: [openshell, nemoclaw, tls, proxy, egress, certifi, httplib2, google-api, sandbox]
---

# OpenShell sandbox: TLS injection + egress allowlist

In OpenShell-managed sandboxes (NemoClaw, etc.) all outbound HTTPS is forced
through a TLS-inspection proxy at `http://10.200.0.1:3128`. The proxy re-signs
every cert with `CN=OpenShell Sandbox CA, O=OpenShell`. Two distinct failure
modes follow.

## Trigger — load this skill when

- Python code (httplib2, google-api-python-client, anything using `certifi`)
  fails with `ssl.SSLCertVerificationError: ... self-signed certificate in
  certificate chain`. The system CA bundle is fine but `certifi` doesn't have
  the OpenShell root.
- `curl` returns `CONNECT tunnel failed, response 403` — that's the proxy
  refusing the CONNECT at the allowlist layer, NOT TLS.
- Gmail tool works but Sheets/Drive/Docs fail. Same root cause as the first
  bullet (Gmail typically works because something — maybe `gws` CLI — uses a
  different code path that already picked up the cert).

## Failure mode 1: TLS verify failure (FIXABLE inside the sandbox)

Symptom: Python `SSLCertVerificationError: self-signed certificate in
certificate chain`.

Root cause: `httplib2.CA_CERTS` resolves to `<pylibs>/certifi/cacert.pem`
(NOT `httplib2/cacerts.txt` — that file is legacy/unused in modern versions).
The certifi bundle ships with Mozilla's trust list, which doesn't include the
OpenShell sandbox root.

Fix (idempotent, durable until next certifi reinstall):

```bash
/sandbox/.hermes/scripts/inject-openshell-ca.sh
```

The script does:
1. Capture the proxy's TLS chain via `openssl s_client -proxy ... -showcerts`
2. Extract the last cert (the root)
3. Append it to `/sandbox/.hermes/pylibs/certifi/cacert.pem` with a comment
   marker so re-runs are no-ops.

Verify the fix:

```bash
env -i \
  PATH=/opt/hermes/.venv/bin:/usr/bin:/bin \
  HOME=/sandbox HERMES_HOME=/sandbox/.hermes \
  PYTHONPATH=/sandbox/.hermes/pylibs \
  HTTPS_PROXY=http://10.200.0.1:3128 HTTP_PROXY=http://10.200.0.1:3128 \
  NO_PROXY=localhost,127.0.0.1,::1 \
  /opt/hermes/.venv/bin/python -c \
  "import httplib2; r,c = httplib2.Http().request('https://sheets.googleapis.com/v4/spreadsheets/x/values/A1', 'GET'); print(r.status, c[:80])"
```

Expect `403` (real Google permission-denied for unauth) rather than
`SSLCertVerificationError`. That's success.

Re-run the script after any `pip install --upgrade certifi` — pip will
overwrite the bundle and lose the injection. Consider adding it to your
sandbox's post-install hook.

## Failure mode 2: proxy CONNECT 403 (NOT fixable inside the sandbox)

Symptom: `curl: (56) CONNECT tunnel failed, response 403` with an 88-byte
JSON body from the proxy. This is the allowlist denying the CONNECT.

This is a NemoClaw / OpenShell policy decision and cannot be worked around
from inside the sandbox. The operator must request the host be added to the
egress allowlist.

### Allowlist as of 2026-06-21 (after expansion)

The allowlist is broad. NextDNS handles malware/phishing/porn/gambling/piracy
filtering at the DNS layer (profile "Spark", host-wide), so OpenShell's
allowlist no longer needs to be the primary defense.

Source of truth for the active set:
[`bringup/50-openshell-policies/web-readonly-egress.yaml`](https://github.com/cecat/Spark-Hermes/blob/main/bringup/50-openshell-policies/web-readonly-egress.yaml)
applied via `nemohermes gandalf policy-add --from-file`.

Categories now covered (incomplete; see the YAML for the full list):

- Wikipedia (`en.wikipedia.org`, `*.wikipedia.org`, wikibooks, wiktionary, commons).
- Research / academic: arXiv, OpenReview, ACM, IEEE, Nature, Science, DOI,
  ACL Anthology.
- Major news: NYT, WaPo, WSJ, BBC, Reuters, AP, NPR, Economist, Guardian,
  Bloomberg, FT, TechCrunch, Verge, Ars, Wired, IEEE Spectrum.
- AI vendor docs / blogs: `*.anthropic.com`, `*.openai.com`, mistral, cohere,
  HuggingFace, paperswithcode, deepmind, ai.meta.com, research.google.
- Charlie's professional context: `*.anl.gov`, energy.gov, nsf.gov,
  trillionparameters.org, tpc26.org, neurips.cc, icml.cc, iclr.cc.
- Academic search APIs (no key needed): `api.semanticscholar.org`,
  `api.crossref.org`, `api.openalex.org`.
- Internet Archive: `archive.org`, `web.archive.org`.
- Commercial search APIs (require API keys in `~/.hermes/.env`):
  `api.exa.ai`, `api.tavily.com`, `api.firecrawl.dev`, `api.jina.ai`,
  `r.jina.ai`, `api.search.brave.com`, `api.serper.dev`, `google.serper.dev`.
- US national labs: ORNL, LBL, LLNL, LANL, NERSC, BNL, FNAL, PNNL (all
  `*.lab.gov`).
- Major universities: `*.uchicago.edu`, `*.utexas.edu`, `*.illinois.edu`,
  `*.mit.edu`, `*.stanford.edu`, `*.berkeley.edu`, `*.cmu.edu`.
- Eventbrite, GitHub raw/api, MDN, ReadTheDocs, Stack Overflow.

Still NOT in the list:

- Pastebins, anonymous file shares (deliberate — prompt-injection bait).
- Anything not above. OpenShell does not support a universal-host wildcard
  in its policy schema — only subdomain wildcards (`*.example.com`). So
  this list is finite by design.

When you genuinely need a host that isn't on the list, ask the operator:

> Please add `<hostname>` to `web-readonly-egress.yaml` in the
> Spark-Hermes repo, then run
> `nemohermes gandalf policy-add --from-file bringup/50-openshell-policies/web-readonly-egress.yaml --yes`.
> Reason: <why>.

NextDNS still blocks malicious-category hosts even after the OpenShell add.

### When you hit a blocked host

1. Check if the data is available via an allowed host first:
   - Many web pages are mirrored on `github.com` or `huggingface.co`.
   - Google Sheets / Docs are reachable via `sheets.googleapis.com` /
     `docs.googleapis.com` (this skill's failure mode 1 fix is required).
   - Scholar/Bing/DDG can search but the result URL is usually on a blocked
     host, so result snippets are useful but full-page fetch typically fails.
2. If genuinely blocked, ask the operator to request the host be added to
   the allowlist. **Tell them exactly what to ask for:**
   > Please add `<hostname>` to the OpenShell sandbox egress allowlist for
   > the NemoClaw-managed Hermes instance (sandbox: `<id>`). Reason: <why>.
3. As a fallback, ask the operator to paste the content directly into chat.

## Pitfalls

- **Don't trust `REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE` env vars for httplib2.**
  httplib2 reads its own bundled path at import time and ignores them.
- **Don't append to `httplib2/cacerts.txt`** — modern httplib2 versions don't
  read it. Use the certifi path (`httplib2.CA_CERTS` reveals it at runtime).
- **Don't conflate the two failure modes.** A 403 from the *proxy* (CONNECT
  failed) is policy, not TLS. A 403 from *Google* (after CONNECT succeeded)
  is auth, not policy. The traceback / curl verbose output tells you which.
- **Don't blame Google or the user when you see "self-signed cert."** That's
  always the OpenShell inspecting proxy. Fix failure mode 1, don't suggest
  the user re-do OAuth.

## Files this skill touches

- `/sandbox/.hermes/pylibs/certifi/cacert.pem` (appended to; .bak made)
- `/sandbox/.hermes/scripts/inject-openshell-ca.sh` (the idempotent injector)
