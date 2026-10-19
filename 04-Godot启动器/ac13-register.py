#!/usr/bin/env python3
"""Freeze/register AC-13 runs. No retries; supplements cannot overwrite primary evidence.

freeze --batch PATH --lap-level N
run --batch PATH --run-id ID  (invokes existing run-check.ps1 with MaxTries=1)
supplement --batch PATH --primary ID --reason TEXT
seal-interrupted --batch PATH --run-id ID --reason TEXT
The JSONL SHA chain detects accidental edits; it is not an adversarial signature.
"""
from __future__ import annotations

import argparse
import contextlib
import ctypes
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("ac13_evidence", Path(__file__).with_name("ac13-evidence.py"))
E = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(E)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


@contextlib.contextmanager
def lock(batch):
    path = Path(batch) / ".register-lock"
    try:
        path.mkdir()
    except FileExistsError as exc:
        raise ValueError("register is locked; do not remove a live run's lock") from exc
    try:
        (path / "owner.json").write_bytes(E.canonical({"pid": os.getpid(), "created_utc": now()}))
        yield
    finally:
        (path / "owner.json").unlink(missing_ok=True)
        path.rmdir()


def append(batch, event, **fields):
    records = E.read_ledger(batch)
    entry = {"event": event, "timestamp_utc": now(),
             "previous": records[-1]["sha256"] if records else "0" * 64, **fields}
    entry["sha256"] = hashlib.sha256(E.canonical(entry)).hexdigest()
    with (Path(batch) / "ledger.jsonl").open("ab") as stream:
        stream.write(E.canonical(entry) + b"\n")
        stream.flush()
        os.fsync(stream.fileno())


def seed_value(repo):
    source = (repo / "godot-racer/scripts/obstacle_field.gd").read_text(encoding="utf-8")
    match = re.search(r"^const SEED\s*:?=\s*(\d+)\s*$", source, re.M)
    if not match:
        raise ValueError("production obstacle seed could not be read")
    return int(match[1])


def freeze(args):
    repo, batch = args.repo.resolve(), args.batch.resolve()
    if batch.exists():
        raise ValueError("freeze requires a new batch directory")
    if any(batch.is_relative_to(repo / directory) for directory in ("godot-racer", "04-Godot启动器")):
        raise ValueError("batch output must be outside production fingerprint directories")
    if not 0 <= args.lap_level <= 4:
        raise ValueError("lap-level must be explicit, zero-based, 0..4")
    identity = E.fingerprints(repo)
    seed = seed_value(repo)
    runs = []
    for check, level, slug in (("lap", args.lap_level, "lap"),
                               ("opponents", 3, "L4"), ("opponents", 4, "L5")):
        for repeat in range(1, 4):
            for fps in ((60, 120) if repeat % 2 else (120, 60)):
                order = len(runs) + 1
                run_id = "AC13-%02d" % order
                log_name = "%s-%s-%s-r%d-fps%d" % (batch.name, run_id, slug, repeat, fps)
                if E.log_path(repo, log_name).exists():
                    raise ValueError("evidence file already exists: " + log_name)
                runs.append({"run_id": run_id, "order": order, "check": check,
                             "level": level, "render_fps": fps, "seed": seed,
                             "repeat": repeat, "log_name": log_name,
                             "timeout_sec": 420 if check == "lap" else 320})
    manifest = {"schema": E.SCHEMA, "created_utc": now(), "lap_level": args.lap_level,
                "repo": str(repo), "identity": identity, "runs": runs,
                "seed_scope": "existing obstacle_field.SEED; no claim that all RNG is controlled",
                "collision_evidence": "existing l4_debug_diag.note_speed proxy; not real Contacts",
                "policy": {"MaxTries": 1, "overwrite": False, "supplements_replace_primary": False}}
    batch.mkdir(parents=True)
    raw = E.canonical(manifest) + b"\n"
    with (batch / "manifest.json").open("xb") as stream:
        stream.write(raw)
    with (batch / "manifest.sha256").open("x", encoding="ascii") as stream:
        stream.write(hashlib.sha256(raw).hexdigest() + "\n")
    with lock(batch):
        append(batch, "FREEZE", manifest_sha256=hashlib.sha256(raw).hexdigest())
    print(str(batch / "manifest.json"))


def find_run(manifest, records, run_id):
    for run in manifest["runs"]:
        if run["run_id"] == run_id:
            return run
    supplements = [r["run"] for r in records if r["event"] == "SUPPLEMENT"
                   and r["run"]["run_id"] == run_id]
    if len(supplements) != 1:
        raise ValueError("unknown/ambiguous run id")
    return supplements[0]


def supplement(args):
    with lock(args.batch):
        manifest = E.load_manifest(args.batch)
        records = E.read_ledger(args.batch)
        primary = next((r for r in manifest["runs"] if r["run_id"] == args.primary), None)
        if primary is None:
            raise ValueError("supplement must reference a primary run")
        if not any(r["event"] == "END" and r.get("run_id") == args.primary for r in records):
            raise ValueError("primary must have a terminal receipt before a supplement")
        number = 1 + sum(r["event"] == "SUPPLEMENT" for r in records)
        run = {**primary, "run_id": "AC13-S%03d" % number,
               "log_name": primary["log_name"] + "-S%03d" % number,
               "supplement_of": args.primary}
        append(args.batch, "SUPPLEMENT", run=run, supplement_of=args.primary, reason=args.reason)
        print(json.dumps(run, ensure_ascii=False))


def execute(args):
    with lock(args.batch):
        manifest = E.load_manifest(args.batch)
        repo = Path(manifest["repo"])
        records = E.read_ledger(args.batch)
        run = find_run(manifest, records, args.run_id)
        if any(r["event"] == "START" and r.get("run_id") == args.run_id for r in records):
            raise ValueError("run already started; never reuse its id/log")
        if "supplement_of" not in run:
            finished = {r["run_id"] for r in records if r["event"] == "END"}
            pending = [r for r in manifest["runs"] if r["run_id"] not in finished]
            if not pending or pending[0]["run_id"] != args.run_id:
                raise ValueError("frozen primary order must be respected")
        if E.fingerprints(repo) != manifest["identity"]:
            raise ValueError("production content changed since freeze; use a new batch")
        logfile = E.log_path(repo, run["log_name"])
        if logfile.exists():
            raise ValueError("refusing to overwrite existing evidence")
        identity = {k: manifest["identity"][k] for k in
                    ("commit", "workspace_fingerprint", "acceptance_contract_hash")}
        identity.update({k: run[k] for k in ("run_id", "check", "level", "render_fps", "seed")})
        # Environment belongs to this child only; no shell-global mutation.
        env = {**os.environ, "AC13_RUN_IDENTITY": json.dumps(identity, ensure_ascii=False)}
        command = ["pwsh", "-NoProfile", "-File", str(repo / "04-Godot启动器/run-check.ps1"),
                   "-Check", run["check"], "-Level", str(run["level"]),
                   "-RenderFps", str(run["render_fps"]), "-LogName", run["log_name"],
                   "-TimeoutSec", str(run["timeout_sec"]), "-MaxTries", "1"]
        common = {"run_id": args.run_id}
        if "supplement_of" in run:
            common["supplement_of"] = run["supplement_of"]
        append(args.batch, "START", **common, command=command, identity=identity)
        code, state, reason = None, "CRASH", ""
        console = args.batch / (run["run_id"] + ".launcher.log")
        try:
            with console.open("xb") as output:
                # No retry here. run-check owns its existing timeout; receipt marks forced kills.
                child = subprocess.Popen(command, cwd=repo, env=env, stdout=output,
                                         stderr=subprocess.STDOUT,
                                         creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
                try:
                    code = child.wait()
                    state = "FINISHED" if code == 0 else "FAILED"
                except KeyboardInterrupt:
                    # Stop the entire process tree, preserving logs; never leave Godot running.
                    if os.name == "nt":
                        subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"],
                                       stdout=output, stderr=subprocess.STDOUT, check=False)
                    else:
                        child.terminate()
                    code = child.wait()
                    state, reason = "CANCELLED", "operator interrupted registered run"
        except OSError as exc:
            reason = str(exc)
        finally:
            try:
                unchanged = E.fingerprints(repo) == manifest["identity"]
            except (OSError, subprocess.CalledProcessError):
                unchanged = False
            append(args.batch, "END", **common, state=state, reason=reason,
                   launcher_exit_code=code,
                   identity_unchanged=unchanged,
                   log_sha256=E.digest(logfile) if logfile.exists() else None,
                   launcher_log_sha256=E.digest(console) if console.exists() else None)
        print(args.run_id + " " + state + " launcher_exit=" + str(code))
        verdict = E.judge(run, manifest["identity"], E.parse_log(logfile), E.read_ledger(args.batch))
        print("EVIDENCE=" + verdict["status"] + " " + "; ".join(verdict["failures"] + verdict["concerns"]))
        return E.EXIT[verdict["status"]]


def interrupted(args):
    # Explicitly records an externally interrupted registrar; cannot manufacture a successful END.
    with lock(args.batch):
        manifest = E.load_manifest(args.batch)
        records = E.read_ledger(args.batch)
        run = find_run(manifest, records, args.run_id)
        history = [r for r in records if r.get("run_id") == args.run_id]
        if not any(r["event"] == "START" for r in history) or any(r["event"] == "END" for r in history):
            raise ValueError("only an unterminated START can be sealed")
        path = E.log_path(manifest["repo"], run["log_name"])
        append(args.batch, "END", run_id=args.run_id, state="CANCELLED", reason=args.reason,
               launcher_exit_code=None, log_sha256=E.digest(path) if path.exists() else None)


def recover_lock(args):
    """Operator attests child tree stopped; a live registrar's lock is never removed."""
    path = args.batch.resolve() / ".register-lock"
    owner = json.loads((path / "owner.json").read_text(encoding="utf-8"))
    pid = int(owner["pid"])
    alive = True
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        kernel.WaitForSingleObject.restype = ctypes.c_ulong
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x00100000, False, pid)
        if handle:
            alive = kernel.WaitForSingleObject(handle, 0) != 0
            kernel.CloseHandle(handle)
        elif ctypes.get_last_error() == 87:  # ERROR_INVALID_PARAMETER: no such process
            alive = False
    else:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            alive = False
    if alive:
        raise ValueError("lock owner still alive or cannot be inspected")
    if not args.process_tree_stopped:
        raise ValueError("explicit process-tree-stopped attestation required")
    (path / "owner.json").unlink()
    path.rmdir()
    with lock(args.batch):
        append(args.batch, "RECOVER_LOCK", reason=args.reason, former_owner=owner,
               process_tree_stopped=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("freeze", "run", "supplement", "seal-interrupted", "recover-lock"):
        p = sub.add_parser(action)
        p.add_argument("--batch", required=True, type=Path)
        if action == "freeze":
            p.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
            p.add_argument("--lap-level", required=True, type=int)
        elif action == "supplement":
            p.add_argument("--primary", required=True)
            p.add_argument("--reason", required=True)
        elif action == "recover-lock":
            p.add_argument("--reason", required=True)
            p.add_argument("--process-tree-stopped", action="store_true")
        else:
            p.add_argument("--run-id", required=True)
            if action == "seal-interrupted":
                p.add_argument("--reason", required=True)
    args = parser.parse_args()
    try:
        result = {"freeze": freeze, "run": execute, "supplement": supplement,
                  "seal-interrupted": interrupted, "recover-lock": recover_lock}[args.action](args)
        return result or 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as exc:
        print("CONCERNS: " + str(exc), file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
