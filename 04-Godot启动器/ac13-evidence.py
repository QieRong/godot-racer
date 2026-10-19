#!/usr/bin/env python3
"""AC-13 evidence reader. No game execution; exit 0/PASS, 1/FAIL, 3/CONCERNS.

Wire format: TAG|JSON (one UTF-8 object per line). Never erase numbers.
PROCESS is a launcher receipt; OUTCOME.exit_code_requested is not a receipt.
An empty Contacts list is not evidence of zero collisions.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

SCHEMA = "ac13/1"
TAGS = {"RUNID", "ASSERT", "OUTCOME", "EVENT", "CONTACT", "COVERAGE", "PROCESS"}
EXIT = {"PASS": 0, "FAIL": 1, "CONCERNS": 3}
ERROR = re.compile(r"SCRIPT ERROR:|Parse Error:|Compilation failed|Failed to load script|"
                   r"Invalid call\. Nonexistent function|ERROR:|Fatal|SIGSEGV|signal 11")


def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args]).decode("utf-8").strip()


def fingerprints(repo):
    """Content identity, including untracked game resources, excluding generated cache/logs."""
    repo = Path(repo).resolve()
    paths = []
    for directory in (repo / "godot-racer", repo / "04-Godot启动器"):
        for path in directory.rglob("*"):
            if not path.is_file() or any(x in {".godot", ".git", "__pycache__"}
                                         for x in path.relative_to(directory).parts):
                continue
            if path.is_symlink():
                raise ValueError("symlink is not a frozen production input: " + str(path))
            paths.append(path)
    entries = {p.relative_to(repo).as_posix(): digest(p) for p in sorted(paths)}
    contract_paths = ["04-Godot启动器/run-all-checks.ps1",
                      "04-Godot启动器/check-readme.ps1"]
    contract_paths += ["godot-racer/scripts/checks/" + n + ".gd"
                       for n in ("layout", "bench", "ai", "ai_field", "env_phys", "basic", "lap")]
    contract = {p: entries[p] for p in contract_paths}
    return {"commit": git(repo, "rev-parse", "HEAD"),
            "workspace_fingerprint": hashlib.sha256(canonical(entries)).hexdigest(),
            "acceptance_contract_hash": hashlib.sha256(canonical(contract)).hexdigest(),
            "files": entries}


def load_manifest(batch):
    batch = Path(batch).resolve()
    raw = (batch / "manifest.json").read_bytes()
    expected = (batch / "manifest.sha256").read_text(encoding="ascii").strip()
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("frozen manifest hash mismatch")
    manifest = json.loads(raw)
    if manifest.get("schema") != SCHEMA:
        raise ValueError("unsupported manifest schema")
    runs = manifest["runs"]
    if len(runs) != 18 or len({x["run_id"] for x in runs}) != 18:
        raise ValueError("manifest must contain exactly 18 distinct primary runs")
    matrix = Counter((x["check"], x["level"], x["render_fps"]) for x in runs)
    wanted = Counter({(check, level, fps): 3 for check, level in
                      (("lap", manifest["lap_level"]), ("opponents", 3), ("opponents", 4))
                      for fps in (60, 120)})
    if matrix != wanted or [x["order"] for x in runs] != list(range(1, 19)):
        raise ValueError("frozen AC-13 matrix/order is invalid")
    if len({x["log_name"] for x in runs}) != 18:
        raise ValueError("duplicate evidence filename")
    return manifest


def read_ledger(batch):
    records = []
    previous = "0" * 64
    path = Path(batch) / "ledger.jsonl"
    if not path.exists():
        return records
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        entry = json.loads(raw)
        seal = entry.pop("sha256")
        if entry.get("previous") != previous or hashlib.sha256(canonical(entry)).hexdigest() != seal:
            raise ValueError("ledger chain broken at line " + str(number))
        entry["sha256"] = seal
        previous = seal
        records.append(entry)
    return records


def log_path(repo, log_name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", log_name):
        raise ValueError("unsafe log name")
    return Path(repo) / "godot-logs" / (log_name + ".log")


def parse_log(path):
    parsed = {tag: [] for tag in TAGS}
    parsed.update(errors=[], malformed=[], complete=False, sha256=None)
    if not path.exists():
        return parsed
    parsed["sha256"] = digest(path)
    text = path.read_text(encoding="utf-8-sig", errors="strict")
    for number, line in enumerate(text.splitlines(), 1):
        if "[CHECK] 完成，退出" in line:
            parsed["complete"] = True
        if ERROR.search(line):
            parsed["errors"].append({"line": number, "text": line})
        match = re.match(r"^(RUNID|ASSERT|OUTCOME|EVENT|CONTACT|COVERAGE|PROCESS)\|(.*)$", line)
        if not match:
            continue
        try:
            value = json.loads(match[2])
            if not isinstance(value, dict):
                raise ValueError("anchor payload must be an object")
            parsed[match[1]].append({"line": number, **value})
        except (ValueError, TypeError) as exc:
            parsed["malformed"].append({"line": number, "error": str(exc)})
    return parsed


def judge(run, identity, parsed, records):
    failures, concerns = [], []
    history = [r for r in records if r.get("run_id") == run["run_id"]]
    starts = [r for r in history if r["event"] == "START"]
    ends = [r for r in history if r["event"] == "END"]
    if len(starts) != 1 or len(ends) != 1:
        concerns.append("exactly one START and END receipt required")
    end = ends[0] if len(ends) == 1 else {}
    if end.get("state") in {"CRASH", "TIMEOUT", "FAILED"}:
        failures.append("registered terminal state: " + end["state"])
    elif end.get("state") != "FINISHED":
        concerns.append("run did not finish normally")
    code = end.get("launcher_exit_code")
    if code is not None and code != 0:
        failures.append("launcher exit code " + str(code))
    if end.get("log_sha256") != parsed["sha256"] or not parsed["sha256"]:
        concerns.append("missing log or log changed after END")
    if end.get("identity_unchanged") is not True:
        concerns.append("production identity changed/unavailable at END")
    if parsed["errors"]:
        failures.append("engine/script error in raw log")
    if parsed["malformed"]:
        concerns.append("malformed structured anchor")
    if not parsed["complete"]:
        concerns.append("missing final CHECK completion marker")
    if len(parsed["RUNID"]) != 1:
        concerns.append("exactly one RUNID required")
    else:
        actual = parsed["RUNID"][0]
        expected = {k: run[k] for k in ("run_id", "check", "level", "render_fps", "seed")}
        expected.update({k: identity[k] for k in
                         ("commit", "workspace_fingerprint", "acceptance_contract_hash")})
        expected.update(physics_hz=120)
        for key, value in expected.items():
            if actual.get(key) != value:
                concerns.append("RUNID mismatch: " + key)
        if not re.match(r"^4\.4\.1(?:[.\s-]|$)", str(actual.get("engine_version", ""))) or actual.get("physics_engine") != "Jolt Physics":
            concerns.append("engine/Jolt identity unavailable or different")
        level_path = "godot-racer/data/levels/level_%d.tres" % (run["level"] + 1)
        if actual.get("level_config_hash") != identity.get("files", {}).get(level_path):
            concerns.append("actual level resource hash missing/different")
        if not isinstance(actual.get("effective_settings"), dict) or not actual["effective_settings"]:
            concerns.append("effective runtime settings unavailable")
    assertions = parsed["ASSERT"]
    if not assertions:
        concerns.append("no executed assertions")
    seen = Counter()
    for assertion in assertions:
        required = {"id", "value", "unit", "threshold", "op", "result", "frame", "kind"}
        if not required.issubset(assertion):
            concerns.append("incomplete assertion: " + str(assertion.get("id")))
        if assertion.get("result") == "FAIL":
            failures.append("assertion failed: " + str(assertion.get("id")))
        if assertion.get("result") not in {"PASS", "FAIL", "SKIP", "INFO"}:
            concerns.append("invalid assertion result")
        if assertion.get("kind") == "contract":
            seen[assertion.get("id")] += 1
    mandatory = (("lap.recovery", "lap.heading_stuck", "lap.laps_reset") if run["check"] == "lap"
                 else ("opponents.initialized", "opponents.finished", "opponents.result"))
    for key in mandatory:
        if seen[key] != 1:
            concerns.append("required assertion missing/duplicated: " + key)
        elif next(a for a in assertions if a.get("id") == key and a.get("kind") == "contract").get("result") not in {"PASS", "FAIL"}:
            concerns.append("required assertion was not executed: " + key)
    if len(parsed["OUTCOME"]) != 1:
        concerns.append("exactly one OUTCOME required")
    else:
        outcome = parsed["OUTCOME"][0]
        if outcome.get("failed_assertions", 0) > 0:
            failures.append("OUTCOME reports failed assertions")
        if outcome.get("check") != run["check"] or outcome.get("finished") is not True:
            concerns.append("OUTCOME check/completion invalid")
        if outcome.get("measurement_status") != "COMPLETE":
            concerns.append("OUTCOME measurement incomplete")
        if outcome.get("assertion_records") != len(assertions):
            concerns.append("assertion stream incomplete/duplicated")
        if outcome.get("failed_assertions") != sum(a.get("result") == "FAIL" for a in assertions):
            concerns.append("failed assertion count differs from stream")
        if not {"completed_laps", "measured_frames", "ai", "failed_assertions"}.issubset(outcome):
            concerns.append("OUTCOME required measurements missing")
        if run["check"] == "lap" and not {"stuck_count", "reset_count"}.issubset(outcome):
            concerns.append("lap stuck/reset counts unavailable")
        if run["check"] == "opponents":
            vehicles = [a for a in assertions if a.get("id") == "opponents.vehicle"]
            if not outcome.get("ai") or len(vehicles) != len(outcome["ai"]):
                concerns.append("opponent per-vehicle assertion coverage incomplete")
        for actor in outcome.get("ai", []):
            if not isinstance(actor, dict) or not {"entity", "laps_done", "rescue_count", "armed"}.issubset(actor):
                concerns.append("AI outcome fields incomplete")
            elif (type(actor["laps_done"]) is not int or type(actor["rescue_count"]) is not int
                    or actor["laps_done"] < 0 or actor["rescue_count"] < 0 or type(actor["armed"]) is not bool):
                concerns.append("AI outcome contains unavailable/invalid readings")
    processes = parsed["PROCESS"]
    if len(processes) != 1:
        concerns.append("exactly one actual process receipt required")
    else:
        process = processes[0]
        if process.get("run_id") != run["run_id"] or process.get("attempt") != 1:
            concerns.append("process identity/retry mismatch")
        if process.get("killed") or process.get("timed_out"):
            failures.append("Godot process killed/timed out")
        if not isinstance(process.get("exit_code"), int):
            concerns.append("actual Godot exit code unavailable")
        elif process["exit_code"] != 0:
            failures.append("Godot process exit code " + str(process["exit_code"]))
    coverage = parsed["COVERAGE"]
    finals = [c for c in coverage if c.get("phase") == "END"]
    if len(finals) != 1 or finals[0].get("sample_frames", 0) <= 0:
        concerns.append("missing/empty frame coverage")
    elif len(finals) == 1:
        # User-approved AC-13 collision definition. Never claim these are real contacts.
        final = finals[0]
        outcome = parsed["OUTCOME"][0] if len(parsed["OUTCOME"]) == 1 else {}
        if (not final.get("collision_proxy_available")
                or final.get("collision_proxy_definition") != "l4_debug_diag.note_speed"
                or len(final.get("collision_proxy_entities", [])) != len(outcome.get("ai", [])) + 1
                or "collision_proxy_count" not in outcome):
            concerns.append("approved collision proxy coverage unavailable")
    if len(finals) == 1:
        first, last = finals[0].get("first_sample_frame"), finals[0].get("last_sample_frame")
        if (not isinstance(first, int) or not isinstance(last, int)
                or last - first + 1 != finals[0].get("sample_frames") or finals[0].get("missing_frame_gaps")):
            concerns.append("frame observation stream has gaps/unverifiable endpoints")
    for tag in ("EVENT", "CONTACT"):
        frames = [x.get("frame") for x in parsed[tag]]
        if any(not isinstance(f, int) for f in frames) or frames != sorted(frames):
            concerns.append(tag + " frames missing/out of order")
    if len(starts) == 1:
        frozen = {k: identity[k] for k in ("commit", "workspace_fingerprint", "acceptance_contract_hash")}
        frozen.update({k: run[k] for k in ("run_id", "check", "level", "render_fps", "seed")})
        if starts[0].get("identity") != frozen:
            concerns.append("START identity differs from frozen manifest")
    return {"status": "FAIL" if failures else "CONCERNS" if concerns else "PASS",
            "failures": sorted(set(failures)), "concerns": sorted(set(concerns))}


def report(batch, repo):
    manifest = load_manifest(batch)
    records = read_ledger(batch)
    primary_ids = {r["run_id"] for r in manifest["runs"]}
    primary_starts = [r["run_id"] for r in records if r["event"] == "START" and r.get("run_id") in primary_ids]
    planned_order = [r["run_id"] for r in manifest["runs"]]
    order_valid = primary_starts == planned_order[:len(primary_starts)]
    rows = []
    for run in manifest["runs"]:
        try:
            parsed = parse_log(log_path(repo, run["log_name"]))
            verdict = judge(run, manifest["identity"], parsed, records)
            if not order_valid:
                verdict["concerns"].append("primary run order differs from frozen order")
                if verdict["status"] == "PASS":
                    verdict["status"] = "CONCERNS"
        except (ValueError, OSError, UnicodeError, TypeError, KeyError, IndexError, AttributeError) as exc:
            parsed = {tag: [] for tag in TAGS}
            verdict = {"status": "CONCERNS", "failures": [], "concerns": [str(exc)]}
        rows.append({"run": run, **verdict, "RunIdentity": parsed["RUNID"],
                     "Assertions": parsed["ASSERT"], "Outcome": parsed["OUTCOME"],
                     "Events": parsed["EVENT"], "Contacts": parsed["CONTACT"],
                     "Coverage": parsed["COVERAGE"], "Process": parsed["PROCESS"],
                     "raw_log_sha256": parsed.get("sha256")})
    statuses = [row["status"] for row in rows]
    groups = {}
    for row in rows:
        if len(row["RunIdentity"]) == 1:
            key = (row["run"]["check"], row["run"]["level"])
            groups.setdefault(key, []).append(row)
    for group in groups.values():
        settings = [r["RunIdentity"][0].get("effective_settings") for r in group]
        if any(value != settings[0] for value in settings):
            for row in group:
                row["concerns"].append("effective settings differ within frozen case")
                if row["status"] == "PASS":
                    row["status"] = "CONCERNS"
        signatures = [Counter(canonical({k: a.get(k) for k in ("id", "unit", "op", "threshold")}) for a in row["Assertions"]
                              if a.get("kind") == "contract") for row in group]
        if any(signature != signatures[0] for signature in signatures):
            for row in group:
                row["concerns"].append("executed contract IDs/units/operators/thresholds differ within case")
                if row["status"] == "PASS":
                    row["status"] = "CONCERNS"
    statuses = [row["status"] for row in rows]
    status = "FAIL" if "FAIL" in statuses else "CONCERNS" if "CONCERNS" in statuses else "PASS"
    supplements = [r for r in records if r.get("supplement_of")]
    return {"schema": SCHEMA, "scope": "AC-13 contract equivalence only",
            "collision_definition": "existing l4_debug_diag.note_speed proxy; real Contacts may be unavailable",
            "status": status, "exit_code": EXIT[status], "primary_runs": rows,
            "supplemental_records": supplements,
            "note": "Historical 518b8e5 evidence is not used; supplemental runs never replace primary runs."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batch", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = report(args.batch, args.repo)
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print("CONCERNS: " + str(exc), file=sys.stderr)
        return 3
    output = args.output or args.batch / "evidence.json"
    output.write_bytes(canonical(result) + b"\n")
    lines = ["run_id\tcheck\tlevel\tfps\tstatus\treasons"]
    for row in result["primary_runs"]:
        run = row["run"]
        lines.append("\t".join(map(str, (run["run_id"], run["check"], run["level"],
                     run["render_fps"], row["status"], "; ".join(row["failures"] + row["concerns"])))))
    table = "\n".join(lines) + "\n"
    output.with_suffix(".tsv").write_text(table, encoding="utf-8")
    print(table, end="")
    print("AC-13=" + result["status"] + " EXIT=" + str(result["exit_code"]))
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
