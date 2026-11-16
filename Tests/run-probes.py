#!/usr/bin/env python3
"""Run the Python probes serially against this checkout's hidden app."""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resume", action="store_true", help="keep recorded entries and run the remaining probes")
    parser.add_argument("--rerun-failed", action="store_true", help="with --resume, rerun failed entries and preserve prior attempts")
    parser.add_argument("--only", nargs="*", help="probe stems to run instead of the full sweep")
    parser.add_argument("--output", type=Path, default=ROOT / ".context/probes")
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if args.rerun_failed and not args.resume:
        parser.error("--rerun-failed requires --resume")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    files = sorted((ROOT / "Tests").glob("*.py"))
    files = [p for p in files if p.name not in ("motion_audit.py", "stacked_spaces_film.py", "fullscreen_tab.py", "speaker_swap_film.py", "pin_mesh_shots.py", "field_appear.py", "quiet_fills_shots.py", "tempo_hud_shots.py", "polish_shots.py", "peek_slide.py", "ring_film.py", "raised_look_shots.py", Path(__file__).name)]
    if args.only is not None:
        files = [p for p in files if p.stem in args.only]
    skipped = {"visual_diff": "needs a before shoot to compare against: run `visual_diff.py shoot` on two builds, then `compare`"}
    for probe in [p for p in files if p.stem in skipped]:
        print(f"{probe.name}: SKIP ({skipped[probe.stem]})", flush=True)
    files = [p for p in files if p.stem not in skipped]
    checkpoint = args.output / "results.json"
    results = json.loads(checkpoint.read_text()) if args.resume and checkpoint.exists() else []
    completed = {row["probe"] for row in results if not (args.rerun_failed and row["exit"] != 0)}
    files = [p for p in files if p.name not in completed]
    lock = ROOT / ".context/probe-lock"
    for probe in files:
        while True:
            try:
                lock.mkdir()
                break
            except FileExistsError:
                time.sleep(0.25)
        command = [sys.executable, "-u", str(probe)]
        if probe.stem == "perf_idle":
            command += ["--hidden", "--local", "--seconds", "3", "--settle", "2"]
        elif probe.stem == "perf_motion":
            command += ["--hidden", "--local", "--runs", "1"]
        elif probe.stem in ("motion_120", "shell_120"):
            command += ["--out", str(args.output / probe.stem), "--runs", "1", "--any-screen", "--no-reference"]
        elif probe.stem == "swipe_120":
            command += ["--out", str(args.output / probe.stem), "--runs", "1", "--any-screen"]
        began = time.monotonic()
        prior_index = next((i for i, row in enumerate(results) if row["probe"] == probe.name), None)
        prior = results[prior_index] if prior_index is not None else None
        attempt = len(prior.get("attempts", [])) + 1 if prior else 0
        filename = f"{probe.stem}-rerun-{attempt}.log" if prior else f"{probe.stem}.log"
        log = args.output / filename
        timed_out = False
        try:
            with log.open("w") as stream:
                process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                           env=dict(os.environ, PYTHONUNBUFFERED="1"))
                try:
                    code = process.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    code = 124
        finally:
            lock.rmdir()
        assertions = [line for line in log.read_text(errors="replace").splitlines()
                      if re.match(r"^\s*FAIL(?:\s|$)", line)]
        if assertions and code == 0:
            code = 1
        result = dict(probe=probe.name, exit=code, seconds=round(time.monotonic() - began, 2),
                      assertion_failures=len(assertions), timed_out=timed_out, log=str(log.relative_to(ROOT)), command=command)
        if prior is not None:
            result["attempts"] = prior.get("attempts", []) + [{k: v for k, v in prior.items() if k != "attempts"}]
            results[prior_index] = result
        else:
            results.append(result)
        (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{probe.name}: {'PASS' if code == 0 else 'FAIL'} ({result['seconds']}s)", flush=True)
        time.sleep(0.5)
    print(f"{sum(r['exit'] == 0 for r in results)}/{len(results)} entry points passed", flush=True)
    return int(any(r["exit"] != 0 for r in results))


if __name__ == "__main__":
    sys.exit(main())
