#!/usr/bin/env python3
import os
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "AgentEdgeFixtures"))
from world import BROADWAY, Site, World

SHOP = b"""<!doctype html><title>Shop</title><h1>Shop</h1>
<p>The basket is empty. The price is 4.20.</p>
<form onsubmit="return false">
<label>Email <input name="email" type="email"></label>
<label>Size <select name="size"><option>Small</option><option>Large</option></select></label>
<label>API key <input name="key" type="password"></label>
<label>Token <input name="token" type="password"></label>
<label>Attach CV <input name="cv" type="file"></label>
<button type="button">Add to basket</button>
<button type="button">Add to basket</button>
<button type="button">Checkout</button>
<button type="button">Apply</button>
</form>
<a href="/prices.csv" download>Price list</a>
<div style="height:3000px"></div>
"""

MISTAKES = ["unknown_command", "Unknown command", "has no option", "doesn't take", "no_tasks"]
TOPICS = [[], ["secrets"], ["pictures"], ["remote"]]


def examples(text):
    found = []
    for line in text.splitlines():
        if not line.startswith("    "):
            continue
        line = line.strip()
        if not re.match(r"(broadway |ssh mac |printf )", line):
            continue
        found.append(re.split(r"\s{2,}#\s", line)[0].strip())
    return found


def run(world, words, stdin):
    try:
        done = subprocess.run([BROADWAY, "--world", world.name, *words], capture_output=True, timeout=25,
                              input=stdin.encode() if stdin is not None else None, stdin=None if stdin is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return 124, "waited for the person", 0
    out = done.stdout.decode(errors="replace")
    return done.returncode, out + done.stderr.decode(errors="replace"), len(done.stdout)


def shaped(line, world, site, tabs, given):
    stdin = None
    if line.startswith("printf "):
        stdin = "s3cret-value-1"
        line = line.split(" | ", 1)[1]
    line = re.sub(r"^ssh mac ", "", line)
    line = re.sub(r"^[A-Z_]+=\S+ ", "", line)
    if " < " in line:
        line = line.split(" < ", 1)[0]
        stdin = "var seen = 1"
    line = re.split(r" [>|] ", line)[0]
    words = shlex.split(line)[1:]
    swapped = []
    for word in words:
        word = word.replace("https://shop.example/help", site.base + "help").replace("https://shop.example", site.base)
        word = word.replace("2c4d6e8f", tabs[0])
        if word.startswith("~/"):
            word = given
        swapped.append(word)
    for flag in ["--to-tab", "--tab"]:
        if flag in swapped and swapped[swapped.index(flag) + 1] == "ID":
            swapped[swapped.index(flag) + 1] = tabs[-1]
    return swapped, stdin


def main():
    world = World("guide", agent="Guide Probe")
    site = Site({"/": SHOP, "/help": SHOP, "/prices.csv": b"item,price\ntea,4.20\n"})
    failures = []
    os.environ["TOKEN"] = "s3cret-value-1"
    given = tempfile.NamedTemporaryFile(prefix="guide-probe-", suffix=".pdf", delete=False)
    given.write(b"%PDF-1.4\n")
    given.close()
    try:
        if not world.start():
            print("FAILED: the test world did not answer", flush=True)
            sys.exit(1)
        lines = []
        for topic in TOPICS:
            said = world.broadway("guide", *topic)
            if said.returncode != 0:
                failures.append("guide " + " ".join(topic))
                print(f"FAIL broadway guide {' '.join(topic)} exits {said.returncode}", flush=True)
                continue
            lines += examples(said.stdout)
        tabs = [world.open(site.base), world.open(site.base + "help")]
        last = [line for line in lines if " agents done" in line]
        lines = [line for line in lines if " agents done" not in line and not line.startswith("ssh -N") and "BROADWAY_SOCKET=" not in line]
        ran = 0
        for line in lines + last:
            words, stdin = shaped(line, world, site, tabs, given.name)
            code, heard, size = run(world, words + ([] if words[0] == "run" else ["--no-person"]), stdin)
            if code == 2 and "--no-person" in heard:
                code, heard, size = run(world, words, stdin)
            binary = "\ufffd" in heard[:8]
            wrong = code == 2 or any(word in heard for word in MISTAKES) or (binary and "-" not in words)
            ran += 1
            first = f"{size} bytes that are not text" if binary else (heard.strip().splitlines()[0][:150] if heard.strip() else "")
            print(f"{'FAIL' if wrong else 'ok  '} {code:3} {line[:86]:86} | {first}", flush=True)
            if wrong:
                failures.append(line)
            if world.questions():
                world.desk({"do": "agents", "action": "answer", "with": "no"})
        if ran < 40:
            failures.append(f"only {ran} example lines were found")
            print(f"FAIL only {ran} example lines were found in the guide", flush=True)
    finally:
        os.unlink(given.name)
        world.stop()
    print("FAILED: " + str(len(failures)) + " of the guide's examples are not commands Broadway takes" if failures else "all good", flush=True)
    sys.exit(1 if failures else 0)


main()
