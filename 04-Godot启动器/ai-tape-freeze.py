#!/usr/bin/env python3
"""Freeze a calibrated player-only command tape; never runs Godot or examines AI scores.

Inputs: calibration candidate, complete chronological calibration history, geometry prereview.
Only the first eligible candidate in that history may be frozen. No overwrite.
This is a calibration-data validity check, not an extra runner acceptance item.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import sys
from pathlib import Path


def raw_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
                       allow_nan=False) + "\n").encode("utf-8")


def eligible(candidate):
    data = candidate.get("calibration", {})
    frames, channels = data.get("frames", []), data.get("channels", [])
    deadline = candidate.get("observation_deadline", {})
    required = int(deadline.get("nominal_physics_frames", 0))
    if candidate.get("state") != "CALIBRATED_NOT_FROZEN" or required <= 0:
        return False
    if data.get("error") or data.get("pending_read_receipts"):
        return False
    if not channels or len(frames) < required or not data.get("geometry_audit"):
        return False
    return all(isinstance(row, list) and len(row) == len(channels)
               and all(isinstance(x, (int, float)) and not isinstance(x, bool)
                       and math.isfinite(x) and 0 <= x <= 1 for x in row) for row in frames)


def freeze(candidate_path, history_path, review_path, output):
    if output.exists():
        raise ValueError("output directory already exists; frozen files are never overwritten")
    candidate = json.loads(candidate_path.read_text(encoding="utf-8-sig"))
    history = json.loads(history_path.read_text(encoding="utf-8-sig"))
    trials = history.get("calibrations", [])
    if not trials:
        raise ValueError("chronological calibration history is required")
    first = None
    for index, trial in enumerate(trials, 1):
        if trial.get("sequence") != index or not trial.get("reason"):
            raise ValueError("history needs consecutive sequence numbers and reasons")
        if trial.get("status") in {"CRASH", "TIMEOUT", "CANCELLED", "NO_CANDIDATE"}:
            if not trial.get("log"):
                raise ValueError("unsuccessful calibration must retain a log/receipt")
            log = (history_path.parent / trial["log"]).resolve()
            if raw_hash(log) != trial.get("log_sha256"):
                raise ValueError("unsuccessful calibration receipt hash mismatch")
            continue
        path = (history_path.parent / trial["file"]).resolve()
        if raw_hash(path) != trial.get("sha256"):
            raise ValueError("calibration history hash mismatch")
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        if value.get("scenario_version") != candidate.get("scenario_version"):
            raise ValueError("do not mix scenario revisions in one calibration history")
        if first is None and eligible(value):
            first = path
    if first != candidate_path.resolve() or not eligible(candidate):
        raise ValueError("only the first eligible chronological candidate can be frozen")
    for key in ("level_config_hash", "track_geometry_hash", "driver_version", "acceptance_contract_hash"):
        value = candidate.get(key)
        if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise ValueError("missing runtime binding: " + key)
    review = json.loads(review_path.read_text(encoding="utf-8-sig"))
    if review.get("track_geometry_hash") != candidate["track_geometry_hash"] or review.get("all_segments_reviewed") is not True:
        raise ValueError("full-track geometry prereview is required before formal freeze")
    if not review.get("reviewer") or not review.get("rationale") or not review.get("segments"):
        raise ValueError("review must identify reviewer, rationale and reviewed track segments")
    # Geometric coverage is an audit of the full course, not a new per-run quota.
    end_arc = float(candidate["calibration"]["geometry_audit"][-1][0])
    covered_to = 0.0
    for segment in sorted(review["segments"], key=lambda s: float(s["from_m"])):
        if float(segment["from_m"]) > covered_to or float(segment["to_m"]) < covered_to:
            raise ValueError("geometry review has a gap/invalid segment")
        if not segment.get("label") or not segment.get("rationale"):
            raise ValueError("each segment needs a geometry label and prior rationale")
        covered_to = float(segment["to_m"])
    if covered_to < end_arc:
        raise ValueError("geometry prereview does not cover the full course")
    data = candidate["calibration"]
    commands = []
    for index, values in enumerate(data["frames"]):
        if commands and values == commands[-1][2]:
            commands[-1][1] = index
        else:
            commands.append([index, index, values])
    tape = {"format": "ai-tape-rle/1", "channels": data["channels"],
            "frame_count": len(data["frames"]), "commands": commands,
            "generation_method": "依据赛道几何与玩家自身跟线能力，不依据 AI 的 60% 成绩优化"}
    tape_bytes = encode(tape)
    manifest = {k: v for k, v in candidate.items() if k != "calibration"}
    manifest.update(state="FROZEN", input_tape_hash=hashlib.sha256(tape_bytes).hexdigest(),
                    input_schedule={"data_file": "input-tape.json", "format": "ai-tape-rle/1",
                                    "frame_count": tape["frame_count"]},
                    coverage_review=review,
                    calibration_candidate_hash=raw_hash(candidate_path),
                    calibration_history_hash=raw_hash(history_path),
                    geometry_review_hash=raw_hash(review_path),
                    selection_rule="first eligible candidate in full chronological history; AI scores ignored")
    output.mkdir(parents=True)
    (output / "input-tape.json").write_bytes(tape_bytes)
    (output / "scenario.json").write_bytes(encode(manifest))
    shutil.copyfile(candidate_path, output / "calibration-source.json")
    shutil.copyfile(history_path, output / "calibration-history.json")
    shutil.copyfile(review_path, output / "geometry-prereview.json")
    return output / "scenario.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--history", required=True, type=Path)
    parser.add_argument("--review", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        print(freeze(args.candidate, args.history, args.review, args.output))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print("NOT_FROZEN: " + str(exc), file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
