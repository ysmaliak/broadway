#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
LOOK = sys.argv[1] if len(sys.argv) > 1 else "light"
POLICY = sys.argv[2] if len(sys.argv) > 2 else "normal"
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

FILM = os.getenv("SEARCH_FILM") == "1"
OUT = ROOT / ".context" / "helm-fade" / f"{LOOK}-{POLICY}"
OUT.mkdir(parents=True, exist_ok=True)
CAPTURE = ROOT / ".context" / "helm-fade" / "capture"
LIT, DIM = 1.0, 0.3


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "Home"
        body = (f'<html style="background:#eef;font:32px system-ui"><title>{name}</title>'
                f"<h1>{name}</h1><p>A stand-in page</p></html>").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"
sv.use("helm-fade-" + uuid.uuid4().hex[:8])
t = sv.T()


def cmd(**r):
    return sv.cmd(r)


def trace(action):
    return cmd(do="ui", helmtrace={"action": action})


for key, value in {"bench": True, "spaces": True, "tabs.groups": False, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                   "tabs.cards": False, "sidebar": True, "start.fresh": False, "split": False}.items():
    subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", str(value).lower()], check=True)
subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", LOOK], check=True)
subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "252"], check=True)
for key, value in {"motion.testReduced": POLICY == "reduced"}.items():
    subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", str(value).lower()], check=True)
if FILM:
    subprocess.run(["swiftc", "-parse-as-library", "Tests/WindowCapture.swift", "-o", str(CAPTURE)], check=True)
subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
for _ in range(200):
    if os.path.exists(sv.SOCK):
        break
    time.sleep(.1)
time.sleep(2)
pid = next(iter(sv.holding() & sv.running()))
log = {"look": LOOK, "policy": POLICY, "cases": {}}


def film(name, action, seconds):
    folder = OUT / name
    for stale in ["ready", "times.json"]:
        if (folder / stale).exists():
            (folder / stale).unlink()
    posture = cmd(do="idle", action="unhide")
    p = subprocess.Popen([str(CAPTURE), pid, str(folder.resolve()), str(seconds), str(posture["number"]), "1", "120"],
                         stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(.025)
    if p.poll() is not None:
        raise RuntimeError(p.communicate()[0])
    time.sleep(.15)
    started = time.time()
    action()
    said = p.communicate()[0]
    print(name, said.strip(), flush=True)
    return {"window": posture["number"], "wall": started, "said": said.strip()}


def run(name, action, expect, seconds=1.2, lead=None):
    trace("start")
    filmed = None
    if FILM:
        filmed = film(name, action, seconds)
    else:
        action()
        time.sleep(seconds)
    stopped = trace("stop")
    traced = stopped["samples"]
    samples = [s for s in traced if not s.get("pending")]
    read = trace("read")
    keys = {}
    for key in ["back", "forward", "reload"]:
        values = [s[key] for s in samples if key in s]
        between = [v for v in values if DIM + 0.02 < v < LIT - 0.02]
        steps = [b - a for a, b in zip(values, values[1:]) if abs(b - a) > 0.0005]
        turns = sum(1 for a, b in zip(steps, steps[1:]) if (a > 0) != (b > 0))
        keys[key] = {"first": values[0] if values else None, "last": values[-1] if values else None,
                     "between": len(between), "turns": turns, "jumps": max([abs(s) for s in steps], default=0)}
    moved = next((s["t"] for s in samples if s.get("offset", 0) != 0), None)
    landed = next((s["t"] for s in samples if s.get("at") != samples[0].get("at")), None)
    changed = {key: next((s["t"] for s in samples if abs(s.get(key, 0) - samples[0].get(key, 0)) > 0.0005), None)
               for key in ["back", "forward", "reload"]}
    case = {"keys": keys, "moved": moved, "landed": landed, "changed": changed, "read": read, "film": filmed,
            "pending": len(traced) - len(samples), "calls": stopped.get("calls", []), "samples": samples}
    log["cases"][name] = case
    print(name, json.dumps({"moved": moved, "landed": landed, "changed": changed,
                            "keys": {k: (v["first"], v["last"], v["between"], v["turns"]) for k, v in keys.items()}}), flush=True)
    doors = {"back": "arrow.left", "forward": "arrow.right", "reload": "reload"}
    for key, want in expect.items():
        k = keys[key]
        looks = [c for c in case["calls"] if c["door"] == doors[key]]
        t.ok(f"{name}: {key} rests {'lit' if want == LIT else 'dim'}", abs(k["last"] - want) < 0.01, k)
        if k["first"] is not None and abs(k["first"] - want) > 0.05:
            if POLICY == "reduced":
                t.ok(f"{name}: {key} changes at once", k["between"] == 0, k)
            else:
                t.ok(f"{name}: {key} is seen fading", k["between"] >= 2, k)
                t.ok(f"{name}: {key} fades once", len(looks) == 1, looks)
    if lead is not None and POLICY != "reduced":
        starts = [v for v in changed.values() if v is not None]
        t.ok(f"{name}: the keys start to fade within {lead} ms of the slide", bool(starts) and moved is not None
             and max(starts) - moved <= lead, {"moved": moved, "changed": changed})
        t.ok(f"{name}: the keys start to fade before the slide lands", bool(starts) and landed is not None
             and max(starts) < landed, {"landed": landed, "changed": changed})
    return case


lit = {"back": LIT, "forward": LIT, "reload": LIT}
dim = {"back": DIM, "forward": DIM, "reload": DIM}
try:
    cmd(do="resize", width=1120, height=760, steps=1)
    posture = cmd(do="idle", action="front")
    first = sv.sp("open", url=base + "/One")["resultID"]
    cmd(do="wait", id=first, seconds=10)
    for name in ["Two", "Three"]:
        sv.ev(first, f"location.href = '{base}/{name}'")
        time.sleep(1.2)
    sv.ev(first, "history.back()")
    time.sleep(1.2)
    second = sv.sp("open", url=base + "/Other")["resultID"]
    cmd(do="wait", id=second, seconds=10)
    sv.sp("select", id=first)
    time.sleep(.8)
    cmd(do="space", action="new", name="Work")
    time.sleep(.8)
    cmd(do="space", action="go", index=1)
    time.sleep(1)
    rested = trace("read")
    log["start"] = rested
    t.ok("the first space's keys are lit", all(abs(rested[k]["rest"] - LIT) < 0.01 for k in lit), rested)
    run("tab", lambda: sv.sp("select", id=second), {"back": DIM, "forward": DIM, "reload": LIT}, .8)
    run("tab-back", lambda: sv.sp("select", id=first), lit, .8)
    run("key", lambda: cmd(do="press", code=19, chars="2", mods=["ctrl"]), dim, lead=100)
    t.ok("Control 2 lands on Work", cmd(do="space")["current"] == "Work")
    run("key-back", lambda: cmd(do="press", code=18, chars="1", mods=["ctrl"]), lit, lead=100)
    run("foot", lambda: cmd(do="space", action="foot", index=2), dim, lead=100)
    run("foot-back", lambda: cmd(do="space", action="foot", index=1), lit, lead=100)
    run("goto", lambda: cmd(do="space", action="goto", index=2), dim, lead=100)
    run("goto-back", lambda: cmd(do="space", action="goto", index=1), lit, lead=100)
    swiped = run("swipe", lambda: cmd(do="space", action="trackpad", stops=[-240], speed=700), dim, 1.6)
    starts = [v for v in swiped["changed"].values() if v is not None]
    t.ok("swipe: the keys start to fade before the slide lands", bool(starts) and swiped["landed"] is not None
         and (POLICY == "reduced" or max(starts) < swiped["landed"]), swiped["changed"])
    t.ok("the swipe lands on Work", cmd(do="space")["current"] == "Work")
    run("swipe-back", lambda: cmd(do="space", action="trackpad", stops=[240], speed=700), lit, 1.6)
    t.ok("the swipe back lands on the first space", cmd(do="space")["current"] != "Work")
    run("swipe-cancel", lambda: cmd(do="space", action="trackpad", stops=[-110], speed=700, cancel=True), lit, 1.6)
    run("swipe-reverse", lambda: cmd(do="space", action="trackpad", stops=[-110, -15], speed=700, momentum=False), lit, 1.6)

    def quick():
        cmd(do="press", code=19, chars="2", mods=["ctrl"])
        time.sleep(float(os.getenv("HELM_QUICK", "0")))
        cmd(do="press", code=18, chars="1", mods=["ctrl"])
    returned = run("quick-return", quick, lit, 1.6)
    if POLICY != "reduced":
        looks = [c for c in returned["calls"] if c["door"] == "arrow.left"]
        t.ok("quick-return: back fades down and turns back up", [c["on"] for c in looks] == [False, True], looks)
        if len(looks) == 2:
            turn = looks[1]
            under_way = turn["runningBegin"] > 0 and turn["t"] - turn["runningBegin"] < 120
            print("quick-return: the turn came", round(turn["t"] - turn["runningBegin"], 1), "ms into the first fade", flush=True)
            if under_way:
                t.ok("quick-return: back turns back from where it is", DIM + 0.01 < turn["shown"] < LIT - 0.01, turn)
            else:
                print("  skip  the turn came after the first fade ended", flush=True)
    t.ok("the quick return ends on the first space", cmd(do="space")["current"] != "Work")
    sv.sp("select", id=first)
    time.sleep(.5)
    (OUT / "log.json").write_text(json.dumps(log, indent=1))
finally:
    try:
        cmd(do="quit")
    except Exception:
        subprocess.run(["kill", pid])
    print("own test world retained:", sv.W, flush=True)

t.done()
sys.exit(1 if t.failed else 0)
