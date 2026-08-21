# Upstream bug report — NemoClaw v0.0.110 rejects Dell-branded GB10 DGX Spark

**Status:** not yet filed. Ready to submit to https://github.com/NVIDIA/NemoClaw/issues
**Found:** 2026-08-20 · **Affects:** every onboard/rebuild on this host
**Consequence for us:** the Hermes/OpenShell/NemoClaw upgrade is **blocked upstream**.
We stay on `v0.0.55` until this is fixed. See `docs/FOLLOWUPS.md` → "Platform upgrade".

---

## Title

`v0.0.110` preflight rejects a Dell-branded GB10 DGX Spark for "failing to be an N1x"

## Summary

**Trigger:** a host whose DMI product name does not match the NVIDIA-branded
patterns **and** which has `/etc/fastos-release` present. A GB10 DGX Spark
shipped under Dell's OEM product name, running the NVIDIA FastOS image, meets
both. (A host with no `/etc/fastos-release` is unaffected — `candidate` stays
`false` and no finding is raised.)

On such a host, `nemoclaw onboard` and `nemoclaw sandbox rebuild` both abort in
preflight with:

```
[1/8] Preflight checks
✗ N1x requires the trusted FastOS marker, NVIDIA PCI identity, Arm64 host,
  and available NVIDIA GPU.
```

The machine is a genuine DGX Spark. It is rejected because the DMI product-name
matcher does not recognise the Dell nameplate, and the fallback N1x probe then
claims the machine and fails it. **The very file that proves it is a DGX Spark
(`/etc/fastos-release`, `NAME="DGX SPARK FASTOS"`) is what drags it into the N1x
branch.**

There is no supported override, so `v0.0.110` cannot create or rebuild a sandbox
on this hardware at all.

## Environment

| | |
|---|---|
| NemoClaw | `v0.0.110` (`9ab3cd3a5`) |
| Previous working version | `v0.0.55` — no N1x check exists in its `src/` |
| OpenShell | `0.0.101` (the exact pin `v0.0.110` requires) |
| Host | Ubuntu 24.04, aarch64, NVIDIA GB10, Docker 29.2.1 |
| Agent | Hermes |

```console
$ cat /sys/class/dmi/id/product_name
Dell Pro Max with GB10 FCM1253

$ cat /etc/fastos-release
NAME="DGX SPARK FASTOS"
DATE="2025-11-12T17:35:20+00:00"
VERSION="1.105.17"
BUILD_TYPE="customer"

$ ls -l /etc/fastos-release
-rw-r--r-- 1 root root 98 Nov 12  2025 /etc/fastos-release

$ uname -m
aarch64
```

## Root cause — a two-step misidentification

### Step 1: the DMI matcher does not know OEM-branded Sparks

`nvidiaPlatformFromProduct` (`src/lib/readiness/platform-qualification.ts:77-89`)
tests only NVIDIA-branded strings:

```ts
if (/DGX[_\s-]+Spark/i.test(productName)) return "spark";
if (/(?<![A-Za-z0-9])P3830(?![A-Za-z0-9])/i.test(productName) || ...) return "station";
if (/Jetson|Tegra|Thor|Orin|Xavier/i.test(productName)) return "jetson";
return undefined;
```

`"Dell Pro Max with GB10 FCM1253"` matches none → `nvidiaPlatform = undefined`.

### Step 2: the fallback N1x probe claims the box, then fails it

Because the platform is unknown, `collectPlatformIdentity`
(`platform-qualification.ts:232-253`) falls through to `collectN1xIdentity`
(`src/lib/inference/platform-identity/n1x.ts:128`), which opens
`/etc/fastos-release`. **`candidate` is set to `true` by the `openFile` call
succeeding — before any byte is read or validated.** On a DGX Spark that file
exists, so the host becomes an N1x candidate purely by running FastOS.

It passes every *trust* check (`root:root`, mode 644, 98 bytes —
`isTrustedN1xFastOsMarker`), but the *content* matcher `isN1xFastOsRelease`
requires the line to be exactly `NAME="N1x FASTOS"`. Ours reads
`NAME="DGX SPARK FASTOS"` → `fastOsMarker = false`.

Then `deriveN1xQualification` (`platform-qualification.ts:312-333`):

```ts
const identity = input.nvidiaPlatform === "n1x" || input.n1xCandidate === true || ...;
// identity = true  (n1xCandidate)
if (identity && input.n1xFastOsMarker === false) status = "unqualified";
```

→ `host.platform.n1x_unqualified`, `severity: "blocking"`
(`platform-qualification.ts:579-587`) → `exitProcess(1)`.

## Why there is no workaround

- **It gates `rebuild`, not just `onboard`.** Call chain verified by reading the
  source: `sandbox rebuild` → `rebuild-pipeline` →
  `preflightAuthoritativeRebuildTarget` (`onboard/authoritative-rebuild-target.ts:221`)
  → `runFatalRuntimePreflight` → `assertOnboardHostReadiness`
  (`onboard/fatal-runtime-preflight.ts:548`) → `projectHostReadiness`
  → `projectPlatformQualification` → hard exit.
- **The one N1x waiver does not apply.** `allowDeferredN1xManagedVllm`
  (`readiness/onboard-admission.ts:125-130`) admits only
  `host.platform.n1x_validation_pending`, not `n1x_unqualified`.
- **`productNamePath` / `fastOsReleasePath` are test-injection function
  options**, not env vars. No `NEMOCLAW_*_PLATFORM` escape hatch exists.
- **`onboard` has no `--skip-preflight`.**

## Suggested fix

Either or both:

1. **Match OEM-branded GB10 Sparks** in `nvidiaPlatformFromProduct` — e.g. treat
   a `GB10` product name as `"spark"`. This is the substantive fix; Dell ships
   GB10 DGX Sparks under its own nameplate and the table only knows NVIDIA's.
2. **Do not let the N1x probe claim a non-N1x FastOS marker.** A
   `/etc/fastos-release` that self-identifies as `DGX SPARK FASTOS` should set
   `candidate = false` (or positively identify the host as `spark`) rather than
   becoming an N1x candidate that then fails. As written, any FastOS variant
   that is not literally N1x fails closed.

A DGX Spark should not be rejected for failing to be an N1x.

## Note on severity

`v0.0.55` has no platform-qualification gate at all — `src/lib/readiness/` does
not exist and `grep -rn "fastos-release\|N1x\|n1x" src/` returns nothing. Its
only DMI read (`src/lib/inference/nim.ts:157`) is for NIM inference sizing and
never gates admission. So this is a regression introduced somewhere in
v0.0.56–v0.0.110 that makes the current release unusable on affected hosts.
Existing sandboxes built on `v0.0.55` keep running; they just cannot be rebuilt
or upgraded.

`v0.0.110` was released 2026-08-18 and is the newest tag on the remote as of
2026-08-20, so this is likely unreported.
