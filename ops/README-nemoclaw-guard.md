# Activating the `nemoclaw` PATH guard

`ops/nemoclaw-guard.sh` is a wrapper that goes on PATH **as `nemoclaw`**. It
inspects argv and the environment, refuses anything not provably aimed at
gandalf / `:8080`, and otherwise `exec`s the real CLI unchanged.

Why it exists: the global `nemoclaw` is hardcoded to one control plane. Aimed
at `:8090`/`:8091` it does not error — it relaunches a gateway there with
plaintext auth and Gandalf's database. `nemoclaw luoji policy-list` did exactly
that on 2026-09-01 and produced a 93-restart loop. The verb was read-only; the
damage comes from the binary reaching `main()`. See the header comment in
`ops/nemoclaw-guard.sh` and the same story in `ops/nmc.sh`.

The guard is **fail-closed**. A false refusal costs five seconds.

---

## What is on PATH today

```
nemoclaw  ->  ~/.local/bin/nemoclaw                     (3-line bash shim)
              -> ~/.nvm/versions/node/v22.22.3/bin/nemoclaw   (symlink)
                 -> ../lib/node_modules/nemoclaw/bin/nemoclaw.js
```

`~/.local/bin` wins the PATH race, so that is the interposition point.

The guard does **not** call `~/.local/bin/nemoclaw` to delegate. It runs
`node` against the module's `bin/nemoclaw.js` by absolute path, deliberately,
so it cannot recurse into itself. The copy you make in step 1 below is a
rollback artifact only — nothing reads it while the guard is active.

---

## Activate

Run these five commands in order, from anywhere.

**1. Preserve the original shim.** Nothing is deleted; this is a copy.

```
cp -p ~/.local/bin/nemoclaw ~/.local/bin/nemoclaw.orig-shim
```

**2. Confirm the copy landed** before anything is overwritten. You should see
two files, both 153 bytes.

```
ls -l ~/.local/bin/nemoclaw ~/.local/bin/nemoclaw.orig-shim
```

**3. Put the guard in place.**

```
cp /home/catlett/code/Spark-Hermes/ops/nemoclaw-guard.sh ~/.local/bin/nemoclaw
```

**4. Make it executable.**

```
chmod 755 ~/.local/bin/nemoclaw
```

**5. Clear the shell's command cache** so this terminal stops using the old
path it memorised.

```
hash -r
```

---

## Smoke test

This is the exact command from the 2026-09-01 incident. It hits the
secondary-plane-name check and `exit`s **before** the real CLI is reached, so
it is safe to run repeatedly.

```
nemoclaw luoji policy-list ; echo "exit=$?"
```

Expected: a `REFUSED by nemoclaw-guard:` block naming `luoji`, advice to use
`bash ops/nmc.sh luoji policy-list`, and `exit=92`.

If you get anything else — real CLI output, `exit=0`, `exit=127` — the guard is
**not** active. Do not proceed; re-check step 3.

Every decision is appended to `~/.nemoclaw-guard.log`.

---

## Undo

Two commands. The original shim is restored from the copy made in step 1.

**1. Put the original back.**

```
cp -p ~/.local/bin/nemoclaw.orig-shim ~/.local/bin/nemoclaw
```

**2. Clear the shell's command cache.**

```
hash -r
```

`~/.local/bin/nemoclaw.orig-shim` can be left in place indefinitely; it is
inert. Removing it is a separate decision.

---

## Escape hatch

If the guard refuses something you are certain about:

```
NEMOCLAW_GUARD_BYPASS=i-understand nemoclaw <args>
```

This runs the real CLI with no checks and logs `verdict=bypass`. It exists so
the guard is never a hard blocker at 2am — not as a routine workaround. If you
reach for it against a secondary plane, the answer you actually want is
`bash ops/nmc.sh <agent> <command>`.

---

## What the guard does NOT protect against

- **`nemohermes` is not guarded at all.** It is a separate binary from the same
  package. `nemohermes gandalf ...` is the sanctioned Gandalf tool and is
  intentionally left alone — but nothing stops `nemohermes` being aimed
  elsewhere.
- **A second PATH entry.** `~/.nvm/versions/node/v22.22.3/bin/nemoclaw` is also
  on PATH, behind `~/.local/bin`. Any shell that puts the nvm bin dir first —
  or anything invoking that absolute path, or `npx nemoclaw`, or
  `node .../bin/nemoclaw.js` — bypasses the guard completely. The guard is a
  PATH convenience, not a sandbox.
- **`npm i -g nemoclaw` re-running.** That rewrites the nvm symlink and may
  restore an unguarded shim. Re-run the smoke test after any npm global install.
- **Agent names it has never heard of.** The name check is hardcoded to `cecat`
  and `luoji`. A future fourth agent is caught only if its name is the *first*
  argument (the fail-closed unknown-leading-token rule). Buried later in the
  argv — e.g. `nemoclaw sandbox <verb> newagent` — it passes. Add new agent
  names to the regex in section 2 of the guard when a plane is added.
- **Anything at all once bypassed.** `NEMOCLAW_GUARD_BYPASS=i-understand`
  disables every check, including the environment ones.
- **Damage from a legitimately-permitted gandalf command.** The guard decides
  *which plane* a command is aimed at. It makes no judgement about whether a
  destructive `:8080` command is a good idea — `nemoclaw gandalf ...` and the
  global verbs delegate straight through.
- **Scripts that were already wrong.** It changes the interactive footgun, not
  any hardcoded absolute path already sitting in a script or unit file.
