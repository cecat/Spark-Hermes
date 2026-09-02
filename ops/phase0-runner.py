#!/usr/bin/env python3
"""mathom Phase 0 grid runner (task C-1.4). Runs on the HOST.

Replaces the 3-hardcoded-probe pilot (`run-ablation-grid.sh`). Key differences:
  - Sessions are isolated via the `X-Hermes-Session-Id` HEADER (needs the API key
    in config.yaml `platforms.api_server.extra.key`), so the pilot's `[grid:]`
    in-prompt tag — flagged by the agent as prompt injection — is GONE. Nothing
    instrumental reaches the model; the payload carries the probe question only.
  - Probe set + N trials from a JSON file.
  - One JSON record per session, appended to an output JSONL.
  - Per-(cell,probe,trial) checkpoint/resume: a completed session is never re-run.
  - Batch by cell: all sessions of one cell run before switching condition.
  - Native memory (MEMORY.md/USER.md) forced OFF for experimental runs (Q5).

Model note: inference is proxy-pinned to claudeopus47 (NEMOCLAW_MODEL); config
model.default is cosmetic. Phase 0 runs on 47 by decision (see mathom runlog).

Condition/answerability is authoritative from the FALDA provider telemetry
(session_open + tool_call, joined on session_id), NOT from this runner's intent.
This file only drives sessions and records raw responses.

Usage:
  phase0-runner.py --probes <probes.json> --out <out.jsonl> --cells <c1,c2,...>
                   [--trials N] [--dry-run]
Cells: nomem_present, tool_present, tool_absent, inject_present, inject_absent
"""
import argparse, json, subprocess, sys, time, hashlib, os, pathlib

CONTAINER_PREFIX = "openshell-gandalf-"
PORT = 18642
COND_PATH_HOST = os.path.expanduser("~/code/Spark-Hermes/gandalf/plugins/falda/condition.yaml")
APPLY = os.path.expanduser("~/code/Spark-Hermes/ops/apply-memory-provider.sh")
KEY_FILE = os.path.expanduser("~/.config/falda/phase0-api-key.env")
CONFIG_IN_SB = "/sandbox/.hermes/config.yaml"

# cell -> (delivery, answerability, prefetch, search_tool, sysblock)
CELLS = {
    "nomem_present":  ("no-memory", "present", False, False, False),
    "tool_present":   ("tool-only", "present", False, True,  False),
    "tool_absent":    ("tool-only", "absent",  False, True,  False),
    "inject_present": ("inject",    "present", True,  False, False),
    "inject_absent":  ("inject",    "absent",  True,  False, False),
}


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, text=True, capture_output=True, **kw)


def container():
    r = sh(f"docker ps --format '{{{{.Names}}}}' | grep '^{CONTAINER_PREFIX}' | head -1")
    name = r.stdout.strip()
    if not name:
        sys.exit("[fatal] no gandalf container running")
    return name


def gw_pid(ct):
    return sh(f'docker exec {ct} sh -c \'pgrep -f "hermes gateway run" | head -1\'').stdout.strip()


def read_key():
    with open(KEY_FILE) as f:
        for line in f:
            if line.startswith("API_SERVER_KEY="):
                return line.split("=", 1)[1].strip()
    sys.exit(f"[fatal] no API_SERVER_KEY in {KEY_FILE}")


def set_condition(ct, cell, label):
    delivery, answ, prefetch, search, block = CELLS[cell]
    # Edit condition.yaml (host copy the plugin reads from), then apply into sandbox.
    import re
    s = open(COND_PATH_HOST).read()
    s = re.sub(r'^condition_label:.*$', f'condition_label: "phase0-{label}"', s, count=1, flags=re.M)
    s = re.sub(r'^prefetch_enabled:.*$', f'prefetch_enabled: {str(prefetch).lower()}', s, count=1, flags=re.M)
    s = re.sub(r'^search_tool_enabled:.*$', f'search_tool_enabled: {str(search).lower()}', s, count=1, flags=re.M)
    s = re.sub(r'^system_prompt_block_enabled:.*$', f'system_prompt_block_enabled: {str(block).lower()}', s, count=1, flags=re.M)
    # share_tool is not part of Phase 0; force it off so it can't confound.
    s = re.sub(r'^share_tool_enabled:.*$', 'share_tool_enabled: false', s, count=1, flags=re.M)
    open(COND_PATH_HOST, "w").write(s)
    r = sh(f"bash {APPLY}")
    if r.returncode != 0:
        sys.exit(f"[fatal] apply-memory-provider failed: {r.stderr}")


def set_native_memory(ct, enabled: bool):
    """Force Hermes built-in MEMORY.md/USER.md on/off (Q5). Phase 0 -> off."""
    py = (
        "import yaml;p='%s';d=yaml.safe_load(open(p,encoding='utf-8-sig')) or {};"
        "m=d.setdefault('memory',{});m['memory_enabled']=%s;m['user_profile_enabled']=%s;"
        "yaml.dump(d,open(p,'w',encoding='utf-8'),default_flow_style=False,sort_keys=False)"
        % (CONFIG_IN_SB, enabled, enabled)
    )
    r = sh(f"docker exec -i -u sandbox {ct} /opt/hermes/.venv/bin/python -c \"{py}\"")
    if r.returncode != 0:
        sys.exit(f"[fatal] could not set native memory flag: {r.stderr}")


def restart_and_wait(ct, timeout_polls=120):
    sh(f"docker restart {ct}")
    # wait for gateway process
    for _ in range(120):
        if sh(f'docker exec {ct} sh -c \'pgrep -f "hermes gateway run" >/dev/null\'').returncode == 0:
            break
        time.sleep(1)
    # wait for api_server health inside netns (re-resolve pid each poll)
    for _ in range(timeout_polls):
        gw = gw_pid(ct)
        if gw:
            r = sh(f"docker exec {ct} sh -c \"nsenter -t {gw} -n curl -s -m 3 http://127.0.0.1:{PORT}/health 2>/dev/null\"")
            if '"status": "ok"' in r.stdout or '"status":"ok"' in r.stdout:
                return True
        time.sleep(2)
    sys.exit("[fatal] gateway did not become healthy after restart")


def ask(ct, gw, key, session_id, question, timeout=180):
    payload = json.dumps({"messages": [{"role": "user", "content": question}], "stream": False})
    cmd = (
        f"docker exec -i {ct} sh -c \"nsenter -t {gw} -n curl -s -m {timeout} "
        f"http://127.0.0.1:{PORT}/v1/chat/completions "
        f"-H 'content-type: application/json' "
        f"-H 'Authorization: Bearer {key}' "
        f"-H 'X-Hermes-Session-Id: {session_id}' "
        f"--data-binary @-\""
    )
    r = subprocess.run(cmd, shell=True, text=True, capture_output=True, input=payload)
    try:
        d = json.loads(r.stdout)
        return {
            "content": d["choices"][0]["message"]["content"],
            "usage": d.get("usage", {}),
            "raw_ok": True,
        }
    except Exception as e:
        return {"content": None, "usage": {}, "raw_ok": False, "error": str(e), "stdout": r.stdout[:300]}


def load_done(out_path):
    done = set()
    if os.path.exists(out_path):
        for line in open(out_path):
            try:
                rec = json.loads(line)
                done.add((rec["cell"], rec["probe_id"], rec["trial"]))
            except Exception:
                pass
    return done


def probes_for(cell, probes):
    _, answ, *_ = CELLS[cell]
    if answ == "present":
        return [(p["id"], p["question"], p.get("answer")) for p in probes["answer_present"]]
    else:
        return [(p["id"], p["question"], None) for p in probes["answer_absent"]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probes", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--cells", required=True, help="comma-separated cell names")
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cells = [c.strip() for c in args.cells.split(",") if c.strip()]
    for c in cells:
        if c not in CELLS:
            sys.exit(f"[fatal] unknown cell {c!r}; valid: {list(CELLS)}")

    probes = json.load(open(args.probes))
    ct = container()
    key = read_key()
    done = load_done(args.out)
    pathlib.Path(os.path.dirname(args.out) or ".").mkdir(parents=True, exist_ok=True)

    total = sum(len(probes_for(c, probes)) * args.trials for c in cells)
    print(f"[plan] container={ct} cells={cells} trials={args.trials} "
          f"total_sessions={total} already_done={len(done)}")
    if args.dry_run:
        for c in cells:
            d, a, pf, se, bl = CELLS[c]
            print(f"  cell {c}: delivery={d} answ={a} prefetch={pf} search={se} block={bl} "
                  f"probes={len(probes_for(c, probes))}")
        return

    outf = open(args.out, "a", encoding="utf-8")
    for cell in cells:  # BATCH BY CELL: all sessions of one cell before switching
        delivery, answ, *_ = CELLS[cell]
        label = cell
        print(f"\n[cell] {cell} (delivery={delivery}, answ={answ}) — setting condition + native mem OFF")
        set_condition(ct, cell, label)
        set_native_memory(ct, False)  # Q5: Phase 0 runs native memory OFF
        restart_and_wait(ct)
        gw = gw_pid(ct)
        plist = probes_for(cell, probes)
        for pid, question, expected in plist:
            for trial in range(1, args.trials + 1):
                keytup = (cell, pid, trial)
                if keytup in done:
                    continue
                sid = f"p0-{cell}-{pid}-t{trial}"
                res = ask(ct, gw, key, sid, question)
                rec = {
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "cell": cell, "delivery": delivery, "answerability": answ,
                    "probe_id": pid, "trial": trial, "session_id": sid,
                    "condition_label": f"phase0-{label}",
                    "question": question, "expected_answer": expected,
                    "response": res.get("content"), "usage": res.get("usage"),
                    "ok": res.get("raw_ok"),
                }
                if not res.get("raw_ok"):
                    rec["error"] = res.get("error"); rec["stdout"] = res.get("stdout")
                outf.write(json.dumps(rec, ensure_ascii=False) + "\n")
                outf.flush()
                status = "ok" if res.get("raw_ok") else "ERR"
                ans = (res.get("content") or "")[:60].replace("\n", " ")
                print(f"    {sid}: [{status}] {ans}")
        print(f"[cell] {cell} complete")
    outf.close()
    print("\n[done] pulling telemetry to host…")
    sh(os.path.expanduser("bash ~/code/Spark-Hermes/ops/pull-telemetry.sh"))
    print("[done] runner finished")


if __name__ == "__main__":
    main()
