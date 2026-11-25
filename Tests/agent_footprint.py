#!/usr/bin/env python3
import argparse
import json
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "AgentEdgeFixtures"))
from footprint_pages import ACTS, PAGES
from world import ROOT, Site, World

DATA = ROOT / "Tests" / "agent_footprint.json"
MARGIN = 0.10
ROUNDS = 3


def steady(text):
    text = re.sub(r"(127\.0\.0\.1|localhost):\d+", lambda m: m.group(1) + ":PORTX", text)
    text = re.sub(r"\b[0-9a-f]{8}\b", "tabidxxx", text)
    text = re.sub(r"\b\d+(\.\d+)? ?(ms|s)\b", lambda m: "0000 " + m.group(2), text)
    text = re.sub(r"(--since|cursor:?|since) \d+", lambda m: m.group(1) + " 000000", text)
    return text


def size(text):
    return len(steady(text).encode())


def measure(world, site):
    numbers = {}
    numbers["guide"] = size(world.broadway("guide").stdout)
    numbers["guide_mcp"] = size(world.broadway("guide", "mcp").stdout)
    client = world.mcp()
    try:
        hello = client.rpc("initialize", {"protocolVersion": "2025-06-18"}).get("result", {})
        numbers["mcp_instructions"] = len(hello.get("instructions", "").encode())
        listing = client.rpc("tools/list").get("result", {})
        numbers["mcp_tools_list"] = len(json.dumps(listing, separators=(",", ":")).encode())
    finally:
        client.close()
    texts = {}
    for page in ACTS:
        tab = world.open(site.base + page)
        shot = world.broadway("snapshot", "--tab", tab)
        numbers[f"snapshot_{page}"] = size(shot.stdout + shot.stderr)
        act = world.broadway(*ACTS[page], "--tab", tab)
        numbers[f"act_{page}"] = size(act.stdout + act.stderr)
        texts[page] = {"snapshot": steady(shot.stdout + shot.stderr), "act": steady(act.stdout + act.stderr), "act_exit": act.returncode}
        world.broadway("close", "--tab", tab)
    return numbers, texts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--texts", type=Path)
    args = parser.parse_args()
    world = World("fp", agent="Footprint Probe")
    site = Site(PAGES)
    failures = []
    try:
        if not world.start():
            print("FAILED: the test world did not answer", flush=True)
            sys.exit(1)
        rounds = []
        texts = {}
        for _ in range(ROUNDS if args.record else 1):
            numbers, texts = measure(world, site)
            rounds.append(numbers)
            time.sleep(1)
        found = {key: max(r[key] for r in rounds) for key in rounds[0]}
        for page, said in texts.items():
            if said["act_exit"] != 0:
                failures.append(f"the act on {page} failed")
                print(f"FAIL the act on {page} failed: {said['act'][:600]}", flush=True)
        if args.texts:
            args.texts.write_text(json.dumps(texts, indent=1))
        if args.record:
            DATA.write_text(json.dumps({"recorded": time.strftime("%Y-%m-%d"), "margin": MARGIN, "bytes": found}, indent=1, sort_keys=True) + "\n")
            for key, value in sorted(found.items()):
                print(f"recorded {key:24} {value:7} bytes  about {value // 4} tokens", flush=True)
        else:
            if not DATA.exists():
                print(f"FAILED: no recorded numbers in {DATA}. Run with --record on a build you trust.", flush=True)
                sys.exit(1)
            recorded = json.loads(DATA.read_text())["bytes"]
            for key, value in sorted(found.items()):
                was = recorded.get(key)
                if was is None:
                    failures.append(f"{key} has no recorded number")
                    print(f"FAIL {key}: {value} bytes, nothing recorded", flush=True)
                    continue
                grew = (value - was) / was if was else 0
                line = f"{key:24} {value:7} bytes, recorded {was:7} ({grew:+.1%})"
                if value > was * (1 + MARGIN):
                    failures.append(key)
                    print("FAIL " + line, flush=True)
                else:
                    print("ok   " + line, flush=True)
    finally:
        world.stop()
    print("FAILED: " + ", ".join(failures) if failures else "all good", flush=True)
    sys.exit(1 if failures else 0)


main()
