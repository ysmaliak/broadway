#!/usr/bin/env python3
"""Automatic folders, scored against the folders a person would make.

Tests/group_lists.json is a fixed set of tab lists, each with the folders a
careful person would make of it and words a good name holds. This runs every
list through the real grouper (AIGrouper.pass) in a hidden probe of its own:
the tabs are seeded asleep with their titles and addresses, so nothing is
loaded from the network, and they land together, one at a time, and one at a
time in reverse.

    ./build.sh && python3 Tests/group_lists.py                 This Mac's model
    python3 Tests/group_lists.py --only picture,one-channel    some lists
    python3 Tests/group_lists.py --repeat 3                    each order three times
    python3 Tests/group_lists.py --names                       the namer alone, on the wanted folders
    python3 Tests/group_lists.py --engine fake                 the test engine, to check the runner
    OPENROUTER_API_KEY=… python3 Tests/group_lists.py --names --engine openrouter --model ~deepseek/deepseek-flash-latest
                                                               the names from a model on OpenRouter, with the key
                                                               from that variable and nowhere else, and the cost
    OPENROUTER_API_KEY=… python3 Tests/group_lists.py --engine openrouter --app
                                                               the key saved the way a person saves it, so the
                                                               app's own order sorts and names
    OPENROUTER_API_KEY=… python3 Tests/group_lists.py --engine openrouter --yes 0.7,0.8
                                                               the grouping from a decision model on OpenRouter,
                                                               once per bar
    python3 Tests/group_lists.py --only picture --orders together --picture
                                                               and a picture of the column after each run

The engine and the namer are pinned to This Mac (SEARCH_REAL_MODEL=1) and the
run stops if they are anything else, so no plan or key is ever reached. With
--engine openrouter only the namer changes: it is the model named by --model,
alone, with no fallback to This Mac, and the run stops at the first failure.
--base sends those asks to a local stub instead of openrouter.ai. The
result, with a trace of every ask, pick, check and name, goes to
.context/after/group-lists/LABEL.json.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unicodedata
from itertools import combinations
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tests"))
parser = argparse.ArgumentParser()
parser.add_argument("--engine", choices=["mac", "fake", "openrouter"], default="mac")
parser.add_argument("--model", default="")
parser.add_argument("--base", default="", help="openrouter: another address for the service, such as a local stand-in")
parser.add_argument("--effort", default="")
parser.add_argument("--only", default="")
parser.add_argument("--orders", default="together,single,reversed")
parser.add_argument("--repeat", type=int, default=1)
parser.add_argument("--names", action="store_true")
parser.add_argument("--label", default="")
parser.add_argument("--set", default=str(ROOT / "Tests" / "group_lists.json"))
parser.add_argument("--picture", action="store_true")
parser.add_argument("--yes", default="", help="openrouter: the bar a pair must reach, or several to sweep, such as 0.6,0.7,0.8")
parser.add_argument("--no", default="", help="openrouter: the bar under which two tabs clash")
parser.add_argument("--namer", choices=["mac", "fake"], default="mac")
parser.add_argument("--app", action="store_true", help="openrouter: save the key the way a person does, so the app's own order sorts and names")
options = parser.parse_args()
sys.argv = sys.argv[:1]
KEY = ""
if not options.model:
    options.model = "~deepseek/deepseek-flash-latest" if options.names else "~typesafe/jev-latest"
if options.engine == "openrouter":
    KEY = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if not KEY:
        raise SystemExit("--engine openrouter reads the key from OPENROUTER_API_KEY on this command and from nowhere else: none given")
if not options.label:
    options.label = "openrouter-" + "".join(ch if ch.isalnum() or ch in ".-" else "-" for ch in options.model).strip("-") \
        + (f"-{options.effort}" if options.effort else "") \
        if options.engine == "openrouter" else "now"
    if "held" in Path(options.set).stem:
        options.label += "-held"
import split_view as sv  # noqa: E402

LISTS = json.loads(Path(options.set).read_text())["lists"]
LIST_WANTS = {entry["id"]: entry["want"] for entry in LISTS}
OUT = ROOT / ".context" / "after" / "group-lists"
WIDTH, HEIGHT, COLUMN = 1000, 620, 258


def ask(request, timeout=900):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(timeout)
        c.connect(sv.SOCK)
        c.sendall(json.dumps(request).encode() + b"\n")
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data.split(b"\n", 1)[0] or b"{}")


def ai(*args, **more):
    return ask({"do": "aigroups", "args": list(args), **more})


def fold(text):
    plain = unicodedata.normalize("NFKD", text.casefold())
    return "".join(ch for ch in plain if not unicodedata.combining(ch))


def batches(entry, order):
    if "batches" in entry:
        return entry["batches"][order]
    keys = [tab["key"] for tab in entry["tabs"]]
    return {"together": [keys], "single": [[key] for key in keys], "reversed": [[key] for key in reversed(keys)]}[order]


def pairs(groups):
    return {frozenset(pair) for group in groups for pair in combinations(sorted(group), 2)}


def named_well(name, wanted):
    said = fold(name)
    if wanted.get("keep"):
        return said == fold(wanted["current"])
    if len(name.split()) > 3 or not said:
        return False
    if wanted.get("name_any") and not any(fold(word) in said for word in wanted["name_any"]):
        return False
    return not any(fold(word) in said for word in wanted.get("name_none", []))


def score(entry, result):
    got = [frozenset(group["keys"]) for group in result["groups"] if group["keys"]]
    want = [frozenset(group["keys"]) for group in entry["want"]]
    accepted = [set(want)] + [{frozenset(group) for group in other} | {w for w, g in zip(want, entry["want"]) if g.get("hand")}
                              for other in entry.get("also", [])]
    made, wished = pairs(got), pairs(want)
    names = []
    for group in result["groups"]:
        wanted = next((w for w in entry["want"] if frozenset(w["keys"]) == frozenset(group["keys"]) and not w.get("hand")), None)
        if wanted is None:
            wanted = next((w for other in entry.get("also", []) for keys in other for w in entry["want"]
                           if frozenset(keys) == frozenset(group["keys"]) and set(keys) <= set(w["keys"])), None)
        if wanted is not None:
            names.append({"name": group["name"], "emoji": group["emoji"], "how": group["how"], "good": named_well(group["name"], wanted)})
    hand_kept = all(any(frozenset(g["keys"]) == frozenset(w["keys"]) and not g["ai"] for g in result["groups"])
                    for w in entry["want"] if w.get("hand"))
    return {"exact": set(got) in accepted and hand_kept, "made": len(made), "wished": len(wished), "both": len(made & wished),
            "names": names, "note": result.get("note", ""), "seconds": round(result.get("seconds", 0), 1),
            "got": [{"name": g["name"], "emoji": g["emoji"], "keys": g["keys"], "how": g["how"]} for g in result["groups"]]}


def picture(name, scratch):
    shot = scratch / "windowshot"
    if not shot.exists():
        shutil.copy(ROOT / "Tests" / "WindowShot.swift", scratch / "WindowShot.swift")
        subprocess.run(["swiftc", "-parse-as-library", "WindowShot.swift", "-o", str(shot)], cwd=str(scratch), check=True)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    time.sleep(1.5)
    pid = next(iter(sv.holding() & sv.running()))
    whole = scratch / f"{name}-whole.png"
    subprocess.run([str(shot), str(pid), str(number), str(whole)], cwd=str(scratch), capture_output=True, text=True)
    if not whole.exists():
        print("  no picture of", name)
        return
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(whole)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(width / WIDTH))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(whole), "-vf",
                    f"crop={(COLUMN + 12) * k}:{HEIGHT * k}:0:0", str(OUT / f"{name}.png")], check=True)
    print("  pictured", OUT / f"{name}.png")


def launch():
    sv.use("group-lists")
    sv.setup(**({"sidebar": True} if options.picture else {}), **{"tabs.groups": True, "ai": True, "ai.groups": True})
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    real = options.engine == "mac" or (options.engine == "openrouter" and (not options.base or (not options.names and options.namer == "mac")))
    env = ["--env", "SEARCH_REAL_MODEL=1"] if real else []
    if options.picture:
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(COLUMN)], check=True)
        env += ["--env", "SEARCH_SHOWN=1"]
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", *env, sv.APP], check=True)
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())
    if options.engine == "openrouter" and options.names:
        ai("mac")
        state = ai("openrouter", options.model, key=KEY, base=options.base, effort=options.effort)
        if state.get("namerModel") != options.model:
            raise SystemExit(f"OpenRouter's {options.model} is not what would name here: nothing run")
    else:
        state = ai("mac") if options.engine == "mac" else ai("fake", "0.05", "0")
    if options.engine == "mac" and (state.get("engine"), state.get("namer")) != ("thisMac", "thisMac"):
        raise SystemExit(f"This Mac's model is not what would decide here ({state.get('engine')}, {state.get('namer')}): nothing run")
    if options.engine == "openrouter" and not options.names:
        state = saved_key() if options.app else openrouter()
    ai("on")
    if options.picture:
        sv.cmd({"do": "resize", "width": WIDTH, "height": HEIGHT, "steps": 1})
    return state


BAR = {"yes": None}


def saved_key():
    ai("mac")
    said = ai("key", "save", key=KEY)
    if not said.get("saved"):
        raise SystemExit(f"the key was not kept ({said.get('trouble', '?')}): nothing run")
    state = ai("state")
    if (state.get("engine"), state.get("namer")) != ("openRouter", "openRouter"):
        raise SystemExit(f"OpenRouter is not what would sort and name here ({state.get('engine')}, {state.get('namer')}): nothing run")
    return state


def openrouter():
    asked = {"key": KEY, "model": options.model, "namer": options.namer}
    if BAR["yes"] is not None:
        asked["yes"] = BAR["yes"]
    if options.no:
        asked["no"] = float(options.no)
    if options.base:
        asked["base"] = options.base
    state = ai("jev", **asked)
    if state.get("engine") != "openrouter":
        raise SystemExit(f"the OpenRouter decider did not start ({state.get('error', '?')}): nothing run")
    print(f"model {state.get('model')} yes {state.get('yes')} no {state.get('no')} namer {state.get('namer')}", flush=True)
    return state


def spent(runs):
    costs = [event["cost"] for run in runs for event in run["trace"] if event.get("kind") == "decisions" and "cost" in event]
    asks = sum(1 for run in runs for event in run["trace"] if event.get("kind") == "decisions")
    return asks, len(costs), sum(costs)


def name_alone(chosen):
    rows = []
    for entry in chosen:
        tabs = {tab["key"]: tab for tab in entry["tabs"]}
        for wanted in entry["want"]:
            if wanted.get("hand") or not wanted.get("name_any"):
                continue
            for turn in range(options.repeat):
                said = ai("name", tabs=[tabs[key] for key in wanted["keys"]], current=wanted.get("current", ""), query=wanted.get("query", ""))
                if "error" in said:
                    raise SystemExit(f"stopped: {said['error']}")
                if options.engine == "openrouter" and "failed" in said.get("how", ""):
                    raise SystemExit(f"stopped: OpenRouter failed on {entry['id']}: {said.get('how')}")
                rows.append({"list": entry["id"], "name": said.get("name", ""), "emoji": said.get("emoji", ""), "how": said.get("how", ""),
                             "current": wanted.get("current", ""), "good": named_well(said.get("name", ""), wanted),
                             "cost": said.get("cost", 0), "seconds": said.get("seconds", 0), "trace": said.get("trace", [])})
                print(f"  {'ok  ' if rows[-1]['good'] else 'MISS'} {entry['id']:28} {rows[-1]['emoji']} {rows[-1]['name']!r:30} {rows[-1]['how'][:60]}", flush=True)
    good = sum(row["good"] for row in rows)
    print(f"names alone: {good} of {len(rows)} good")
    if options.engine == "openrouter":
        print(f"cost of these names on OpenRouter: ${sum(row['cost'] for row in rows):.5f}")
    if rows:
        times = sorted(row["seconds"] for row in rows)
        print(f"seconds a name: median {times[len(times) // 2]:.1f}, slowest {times[-1]:.1f}")
    held = [row for row in rows if row["current"]]
    if held:
        print(f"names with a current name: {sum(row['good'] for row in held)} of {len(held)} right (kept where it still fits, changed where it does not)")
    return rows


def main():
    wanted = [word for word in options.only.split(",") if word]
    chosen = [entry for entry in LISTS if not wanted or entry["id"] in wanted]
    orders = [word for word in options.orders.split(",") if word]
    OUT.mkdir(parents=True, exist_ok=True)
    runs, names = [], []
    scratch = Path(tempfile.mkdtemp(prefix="group-lists-"))
    try:
        state = launch()
        print("engine", state.get("engine"), "namer", state.get("namer"), flush=True)
        if options.names:
            names = name_alone(chosen)
        else:
            for entry in chosen:
                for order in orders:
                    for turn in range(options.repeat):
                        trial = {"tabs": entry["tabs"], "folders": entry.get("folders", []), "batches": batches(entry, order)}
                        result = ai("trial", trial=trial)
                        if "error" in result:
                            print("stopped:", result["error"], flush=True)
                            raise KeyboardInterrupt
                        found = score(entry, result)
                        found.update({"list": entry["id"], "order": order, "turn": turn, "trace": result.get("trace", [])})
                        runs.append(found)
                        shown = "; ".join(f"{g['emoji']} {g['name']} [{', '.join(g['keys'])}]" for g in found["got"]) or "no folders"
                        print(f"  {'ok  ' if found['exact'] else 'MISS'} {entry['id']:28} {order:9} {found['seconds']:6.1f}s  {shown}"
                              + (f"  ({found['note']})" if found["note"] else ""), flush=True)
                        if options.picture:
                            picture(f"{options.label}-{entry['id']}-{order}", scratch)
    except KeyboardInterrupt:
        print("stopped early: what ran is scored below", flush=True)
    finally:
        sv.finish()
    if runs:
        print()
        right_lists = 0
        for entry in chosen:
            mine = [run for run in runs if run["list"] == entry["id"]]
            if not mine:
                continue
            right = sum(run["exact"] for run in mine)
            right_lists += right == len(mine)
            labels = [name for run in mine for name in run["names"]]
            print(f"{entry['id']:28} folders right {right}/{len(mine)}   names good {sum(n['good'] for n in labels)}/{len(labels)}")
        made, wished, both = (sum(run[key] for run in runs) for key in ("made", "wished", "both"))
        labels = [name for run in runs for name in run["names"]]
        print()
        print(f"runs with exactly the wanted folders: {sum(run['exact'] for run in runs)} of {len(runs)}")
        print(f"lists right in every run: {right_lists} of {len({run['list'] for run in runs})}")
        print(f"pairs put together that belong together: {both} of {made} made ({both / made:.0%})" if made else "pairs made: 0")
        print(f"pairs that belong together and were put together: {both} of {wished} wanted ({both / wished:.0%})" if wished else "pairs wanted: 0")
        print(f"names good on rightly made folders: {sum(n['good'] for n in labels)} of {len(labels)}")
        print(f"runs that ended with a note (a failure or a timeout): {sum(bool(run['note']) for run in runs)}")
    if options.engine == "openrouter":
        asks, priced, cost = spent(runs)
        print(f"requests to {options.model}: {asks}, cost from usage.cost: ${cost:.6f}"
              + ("" if priced == asks else f" ({asks - priced} requests did not report a cost)"))
    file = OUT / f"{options.label}.json"
    file.write_text(json.dumps({"engine": options.engine, "base": options.base,
                                "model": (options.model + (f" {options.effort}" if options.effort else "")) if options.engine == "openrouter" else "",
                                "set": Path(options.set).name, "runs": runs, "names": names}, indent=1, ensure_ascii=False))
    print("written", file)
    if names:
        side_by_side(Path(options.set).name)
    return runs


def side_by_side(set_name):
    found = []
    for path in sorted(OUT.glob("*.json")):
        try:
            data = json.loads(path.read_text())
        except ValueError:
            continue
        if data.get("base"):
            continue
        if data.get("names") and data.get("set", set_name) == set_name and (data.get("engine") == "openrouter" or path.stem == options.label):
            found.append((data.get("model") or path.stem, data["names"]))
    if len(found) < 2:
        return
    print()
    print("names side by side:")
    width = 26
    print(" " * 30 + "".join(f"{label[:width]:{width + 2}}" for label, _ in found))
    keys = []
    for _, rows in found:
        for index, row in enumerate(rows):
            key = (row["list"], sum(1 for other in rows[:index] if other["list"] == row["list"]))
            if key not in keys:
                keys.append(key)
    for key in keys:
        cells = []
        for _, rows in found:
            same = [row for row in rows if row["list"] == key[0]]
            row = same[key[1]] if key[1] < len(same) else None
            cells.append(("" if row is None else ("  " if row["good"] else "✗ ") + row["name"])[:width])
        print(f"{key[0][:28]:30}" + "".join(f"{cell:{width + 2}}" for cell in cells))
    print("".ljust(30) + "".join(f"{(str(sum(r['good'] for r in rows)) + ' of ' + str(len(rows)) + ' good  $' + format(sum(r.get('cost', 0) for r in rows), '.5f'))[:width]:{width + 2}}" for _, rows in found))


def sweep():
    bars = [float(word) for word in options.yes.split(",") if word]
    if options.engine != "openrouter" or len(bars) < 2:
        if bars:
            BAR["yes"] = bars[0]
        main()
        return
    label, rows = options.label, []
    for bar in bars:
        BAR["yes"] = bar
        options.label = f"{label}-yes{bar}"
        print(f"\n== bar {bar} ==", flush=True)
        runs = main() or []
        made, wished, both = (sum(run[key] for run in runs) for key in ("made", "wished", "both"))
        empty = [run for run in runs if not any(LIST_WANTS.get(run["list"], []))]
        wrong = sum(1 for run in empty if run["made"])
        rows.append((bar, sum(run["exact"] for run in runs), len(runs), both, made, wished, wrong, len(empty), spent(runs)[2]))
    print("\nbar   exact runs   pairs right of made   pairs found of wanted   folders on unrelated lists   cost")
    for bar, exact, count, both, made, wished, wrong, empty, cost in rows:
        print(f"{bar:<5} {exact:>3} of {count:<5} {both:>4} of {made:<14} {both:>4} of {wished:<17} {wrong:>3} of {empty:<22} ${cost:.6f}")


if __name__ == "__main__":
    sweep()
