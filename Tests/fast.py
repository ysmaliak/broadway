#!/usr/bin/env python3
import argparse
import json
import math
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TIMES = ROOT / ".build" / "fast-times.json"
ISOLATED = {"SearchTests.DownloadLifecycleTests": 7}
BUDGET = 120.0
ANSI = re.compile(r"\x1b\[[0-9;]*m")
LOCATION = re.compile(r"/[^/]+\.swift:\d+:\d+$")


def parse():
    parser = argparse.ArgumentParser(description="Run the Swift tests in parallel shards with a watchdog.")
    parser.add_argument("--jobs", type=int, default=int(os.environ.get("FAST_JOBS", "6")))
    parser.add_argument("--filter", action="append", default=[], help="only suites or tests whose id matches")
    parser.add_argument("--repeat", type=int, default=1, help="run this many times; stop at the first failure")
    parser.add_argument("--quiet", type=float, default=90, help="seconds without output before a shard is killed")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--logs", default=str(ROOT / ".build" / "fast-logs"))
    return parser.parse_args()


def build():
    started = time.monotonic()
    result = subprocess.run(["swift", "build", "--build-tests"], cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout[-6000:] + result.stderr[-6000:])
        print("BUILD FAILED")
        sys.exit(2)
    print(f"built in {time.monotonic() - started:.0f} s", flush=True)


def listed():
    result = subprocess.run(["swift", "test", "list", "--skip-build"], cwd=ROOT,
                            capture_output=True, text=True, check=True)
    tests = [line.strip() for line in result.stdout.splitlines() if re.match(r"^\w+\.\w+/", line.strip())]
    if not tests:
        raise SystemExit("swift test list found no tests")
    return tests


def suite_of(test):
    return test.split("/", 1)[0]


def plan(tests, jobs, weights, filters):
    if filters:
        wanted = [re.compile(f) for f in filters]
        tests = [t for t in tests if any(w.search(t) for w in wanted)]
    suites = {}
    for test in tests:
        suites.setdefault(suite_of(test), []).append(test)
    singles = []
    shared = {}
    for suite, members in suites.items():
        if suite in ISOLATED:
            if not filters and len(members) != ISOLATED[suite]:
                raise SystemExit(f"expected {ISOLATED[suite]} isolated cases in {suite}, found {members}")
            singles += [[test] for test in members]
        else:
            shared[suite] = members
    room = jobs - 1 if singles and jobs > 2 else jobs

    def weight(suite):
        return weights.get(suite, 0.05 * len(shared[suite]) + 0.2)

    wanted = max(room, math.ceil(sum(weight(s) for s in shared) / BUDGET))
    bins = [[] for _ in range(max(1, min(wanted, len(shared))))]
    loads = [0.0] * len(bins)
    for suite in sorted(shared, key=lambda s: -weight(s)):
        index = loads.index(min(loads))
        bins[index].append(suite)
        loads[index] += weight(suite)
    if filters:
        work = [("tests", [t for s in b for t in shared[s]], sum(len(shared[s]) for s in b)) for b in bins if b]
    else:
        work = [("suites", b, sum(len(shared[s]) for s in b)) for b in bins if b]
    work += [("test", s, 1) for s in singles]
    expected = {t for t in tests}
    return work, expected


def pattern(kind, names):
    if kind == "test":
        return [f"^{re.escape(names[0])}(/|$)"]
    if kind == "tests":
        return [f"^{re.escape(name)}(/|$)" for name in names]
    return ["^(" + "|".join(re.escape(n) for n in names) + ")(/|$)"]


class Job:
    def __init__(self, index, kind, names, count, logs, run_id):
        self.index = index
        self.kind = kind
        self.names = names
        self.count = count
        self.world = f"fast-{run_id}-{index}"
        self.log = logs / f"job-{index}.log"
        self.events = logs / f"job-{index}.jsonl"
        self.turns = logs / f"job-{index}.turns"
        self.process = None
        self.fd = None
        self.buffer = ""
        self.heard = time.monotonic()
        self.started_at = None
        self.ended_at = None
        self.hung = None
        self.running = {}
        self.code = None

    def label(self):
        if self.kind == "test":
            return self.names[0]
        if self.kind == "tests":
            return f"shard {self.index} ({self.count} tests)"
        return f"shard {self.index} ({len(self.names)} suites, {self.count} tests)"

    def start(self):
        for path in (self.log, self.events, self.turns):
            path.unlink(missing_ok=True)
        env = dict(os.environ, SEARCH_PROBE=self.world, BROADWAY_TEST_TURNS=str(self.turns))
        command = ["swift", "test", "--skip-build", "--ignore-lock", "--disable-xctest",
                   "--event-stream-output-path", str(self.events), "--event-stream-version", "0"]
        for filter_ in pattern(self.kind, self.names):
            command += ["--filter", filter_]
        main, child = pty.openpty()
        self.process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                        stdout=child, stderr=child, start_new_session=True)
        os.close(child)
        self.fd = main
        self.handle = open(self.log, "w")
        self.started_at = time.monotonic()
        self.heard = self.started_at

    def read(self):
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if not data:
            return False
        self.heard = time.monotonic()
        text = ANSI.sub("", data.decode(errors="replace")).replace("\r", "")
        self.handle.write(text)
        self.buffer += text
        *lines, self.buffer = self.buffer.split("\n")
        for line in lines:
            started = re.search(r"◇ Test (.+?) started\.", line)
            if started:
                self.running[started.group(1)] = self.running.get(started.group(1), 0) + 1
            ended = re.search(r"[✔✘➜] Test (.+?) (passed|failed|skipped)", line)
            if ended and ended.group(1) in self.running:
                self.running[ended.group(1)] -= 1
                if self.running[ended.group(1)] <= 0:
                    del self.running[ended.group(1)]
        return True

    def holder(self):
        if not self.turns.exists():
            return None
        open_turns = {}
        for line in self.turns.read_text(errors="replace").splitlines():
            first, _, test = line.partition("\t")
            if first == "held":
                open_turns[test] = open_turns.get(test, 0) + 1
            elif test in open_turns:
                open_turns[test] -= 1
                if open_turns[test] <= 0:
                    del open_turns[test]
        return sorted(open_turns) or None

    def kill(self, reason):
        self.hung = reason
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def finish(self):
        self.code = self.process.wait()
        self.ended_at = time.monotonic()
        while self.read():
            pass
        os.close(self.fd)
        self.handle.close()
        sweep(self.world)


def sweep(world):
    home = Path.home()
    for folder in (home / "Library" / "Application Support").glob(f"Broadway ({world}-*)"):
        shutil.rmtree(folder, ignore_errors=True)
    for plist in (home / "Library" / "Preferences").glob(f"com.ysmaliak.broadway.test.{world}-*.plist"):
        subprocess.run(["defaults", "delete", plist.stem], capture_output=True)
        plist.unlink(missing_ok=True)


def results(job):
    tests, ended, skipped, issues, started = {}, set(), set(), {}, {}
    durations = {}
    if job.events.exists():
        for line in job.events.read_text(errors="replace").splitlines():
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = record.get("payload", {})
            if record.get("kind") == "test":
                tests[payload["id"]] = payload
                continue
            kind = payload.get("kind")
            test = payload.get("testID")
            if not test:
                continue
            base = LOCATION.sub("", test)
            if "/" not in base:
                continue
            instant = payload.get("instant", {}).get("absolute", 0)
            if kind == "testStarted":
                started[base] = instant
            elif kind == "testEnded":
                ended.add(base)
                if base in started:
                    durations[base] = instant - started[base]
            elif kind == "testSkipped":
                skipped.add(base)
            elif kind == "issueRecorded":
                if payload.get("issue", {}).get("isKnown"):
                    continue
                text = " ".join(m.get("text", "") for m in payload.get("messages", []))
                issues.setdefault(base, []).append(text)
    held = {}
    if job.turns.exists():
        for line in job.turns.read_text(errors="replace").splitlines():
            first, _, test = line.partition("\t")
            if first == "leak":
                continue
            if first != "held":
                held[LOCATION.sub("", test)] = held.get(LOCATION.sub("", test), 0) + float(first)
    return ended, skipped, issues, durations, held


def run_once(args, tests, weights, logs, round_index):
    run_id = uuid.uuid4().hex[:6]
    work, expected = plan(tests, args.jobs, weights, args.filter)
    jobs = [Job(i, kind, names, count, logs, run_id) for i, (kind, names, count) in enumerate(work)]
    waiting = list(jobs)
    active = []
    began = time.monotonic()
    print(f"round {round_index}: {len(expected)} tests in {len(jobs)} processes, {args.jobs} at a time", flush=True)
    while waiting or active:
        while waiting and len(active) < args.jobs:
            job = waiting.pop(0)
            job.start()
            active.append(job)
        ready, _, _ = select.select([j.fd for j in active], [], [], 1.0)
        for job in list(active):
            if job.fd in ready and not job.read() and job.process.poll() is not None:
                job.finish()
                active.remove(job)
                continue
            if job.process.poll() is not None:
                job.finish()
                active.remove(job)
                continue
            quiet = time.monotonic() - job.heard
            if quiet > args.quiet:
                holder = job.holder()
                stuck = holder or sorted(job.running)[:8]
                print(f"STUCK {job.label()}: no output for {quiet:.0f} s; killing it", flush=True)
                for test in stuck:
                    print(f"  stuck: {test}", flush=True)
                job.kill(stuck)
    wall = time.monotonic() - began
    return summarise(jobs, expected, wall, weights, args)


def summarise(jobs, expected, wall, weights, args):
    ended, skipped, failures, durations, held = set(), set(), {}, {}, {}
    hung = []
    for job in jobs:
        e, s, i, d, h = results(job)
        ended |= e
        skipped |= s
        failures.update(i)
        durations.update(d)
        held.update(h)
        if job.hung:
            hung.append((job, job.hung))
        elif job.code not in (0, None) and not i:
            failures.setdefault(job.label(), [f"exited {job.code} with no failed test; see {job.log}"])
    missing = sorted(t for t in expected if t not in ended and t not in skipped)
    timing = {t: held.get(t, durations.get(t, 0)) for t in ended}
    suites = {}
    for test, seconds in timing.items():
        suites[suite_of(test)] = suites.get(suite_of(test), 0) + seconds
    if not args.filter:
        TIMES.parent.mkdir(parents=True, exist_ok=True)
        TIMES.write_text(json.dumps({**weights, **suites}, indent=1, sort_keys=True))
    failed = sorted(failures)
    print()
    print(f"total {wall:.1f} s: {len(ended)} ran, {len(skipped)} skipped, {len(failed)} failed, "
          f"{len(missing)} never ran, {len(hung)} hung")
    for job, stuck in hung:
        print(f"HUNG {job.label()}: {', '.join(stuck) if stuck else 'no test named'}  (log {job.log})")
    for test in failed:
        print(f"FAILED {test}")
        for message in failures[test][:3]:
            print(f"    {message[:300]}")
    if missing and not hung:
        print(f"NEVER RAN {len(missing)}: {', '.join(missing[:10])}")
    print("slowest:")
    for test, seconds in sorted(timing.items(), key=lambda item: -item[1])[:10]:
        print(f"  {seconds:6.2f} s  {test}")
    return not failed and not missing and not hung, wall


def main():
    args = parse()
    os.chdir(ROOT)
    if not args.skip_build:
        build()
    tests = listed()
    weights = {}
    if TIMES.exists():
        try:
            weights = json.loads(TIMES.read_text())
        except json.JSONDecodeError:
            weights = {}
    logs = Path(args.logs)
    logs.mkdir(parents=True, exist_ok=True)
    walls = []
    for round_index in range(1, args.repeat + 1):
        ok, wall = run_once(args, tests, weights, logs, round_index)
        walls.append(wall)
        if not ok:
            print(f"FAILED in round {round_index} of {args.repeat}")
            sys.exit(1)
    if args.repeat > 1:
        print(f"all {args.repeat} rounds green; walls: {', '.join(f'{w:.0f}' for w in walls)} s")


if __name__ == "__main__":
    main()
