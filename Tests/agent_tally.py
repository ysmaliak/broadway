#!/usr/bin/env python3
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "AgentEdgeFixtures"))
from world import BROADWAY, Ledger, Site, World

MARK = "plum-secret-7731"
PAGE = f"""<!doctype html><title>Tally {MARK}</title><h1>Tally</h1><p>Page words {MARK}</p>
<button type="button" onclick="document.title = 'pressed'">Press</button>"""

ledger = Ledger()


def counts(world):
    _, parsed = world.envelope("doctor", "--calls")
    rows = (parsed.get("data") or {}).get("commands") or []
    return {row["command"]: row for row in rows}, parsed


def row(found, command):
    return found.get(command) or {"calls": 0, "failed": 0, "codes": {}}


def settle(world, condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found, _ = counts(world)
        if condition(found):
            return found
        time.sleep(0.25)
    return counts(world)[0]


def main():
    world = World("tally", agent="Tally Probe")
    site = Site({"/": PAGE, "*": PAGE})
    check = ledger.check
    try:
        if not world.start():
            check("tally", "the test world answers", False)
            sys.exit(ledger.finish())
        tab = world.open(site.base + f"?q={MARK}")
        missed, parsed = world.envelope("click", "Nothing named so", "--tab", tab)
        check("tally", "a click on words that fit nothing fails", (parsed.get("error") or {}).get("code") == "not_found", parsed)
        world.broadway("click", "Press", "--tab", tab)
        usage = world.broadway("scroll", "sideways", MARK, "--tab", tab)
        check("tally", "a usage mistake exits 2", usage.returncode == 2, usage.stdout + usage.stderr)
        unknown = world.broadway("clik", "@e9", MARK)
        check("tally", "an unknown command exits 2", unknown.returncode == 2, unknown.stdout + unknown.stderr)
        world.broadway("logins", "list")
        client = world.mcp()
        try:
            client.rpc("initialize", {"protocolVersion": "2025-06-18"})
            client.call("click", tab=tab, target="Nothing named so either")
            client.call("read", tab=tab)
            client.rpc("tools/call", {"name": f"no_such_tool_{MARK.replace('-', '_')}", "arguments": {}})
        finally:
            client.close()

        found = settle(world, lambda f: row(f, "click")["calls"] >= 3 and row(f, "read")["calls"] >= 1)
        click = row(found, "click")
        check("tally", "clicks from the command and from MCP are counted", click["calls"] == 3 and click["codes"].get("not_found") == 2, found)
        check("tally", "a read over MCP is counted under the command's own word", row(found, "read")["calls"] == 1 and row(found, "read")["failed"] == 0
              and "text" not in found, found)
        check("tally", "open and wait are counted by their command words", row(found, "open")["calls"] == 1 and row(found, "wait")["calls"] >= 1, found)
        check("tally", "the command's own usage mistake is counted under its command", row(found, "scroll")["codes"].get("usage") == 1, found)
        check("tally", "an unknown command and an unknown tool count as other", row(found, "other")["codes"].get("usage") == 1
              and row(found, "other")["codes"].get("unknown_tool") == 1, found)
        check("tally", "a person verb is counted by noun and verb", row(found, "logins list")["codes"].get("person_only") == 1, found)
        stored = (world.folder / "agent-calls.json").read_text() if (world.folder / "agent-calls.json").exists() else ""
        check("tally", "the count is kept on disk", '"click"' in stored, stored)
        check("tally", "the file holds no address, page words or arguments",
              stored and MARK not in stored and "127.0.0.1" not in stored and "Nothing named" not in stored and "sideways" not in stored
              and "clik" not in stored and "plum" not in stored, stored)
        plain = world.broadway("doctor", "--calls")
        lines = plain.stdout.splitlines()
        check("tally", "doctor --calls prints a table", plain.returncode == 0 and any(l.startswith("command") and "calls" in l and "failed" in l for l in lines)
              and any(l.startswith("click") and "not_found 2" in l for l in lines), plain.stdout + plain.stderr)
        extra = world.broadway("doctor", "--calls", "now")
        check("tally", "doctor --calls takes nothing more", extra.returncode == 2, extra.stdout + extra.stderr)
        alias = world.broadway("doctor", "--failures")
        check("tally", "doctor --failures still answers as doctor --calls", alias.returncode == 0 and alias.stdout == plain.stdout, alias.stdout + alias.stderr)

        check("tally", "Broadway quits", world.quit())
        after = subprocess.run([BROADWAY, "--world", world.name, "doctor", "--calls", "--json"], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        kept = {r["command"]: r for r in json.loads(after.stdout or "{}").get("data", {}).get("commands", [])}
        check("tally", "doctor --calls reads the count while Broadway is not running", row(kept, "click")["calls"] == 3, after.stdout + after.stderr)
        check("tally", "Broadway starts again", world.launch())
        tab = world.open(site.base)
        world.broadway("click", "Press", "--tab", tab)
        found = settle(world, lambda f: row(f, "click")["calls"] >= 4)
        check("tally", "after a relaunch the count goes on from where it was", row(found, "click")["calls"] == 4 and row(found, "click")["codes"].get("not_found") == 2, found)

        world.desk({"do": "agents", "action": "mode", "mode": "auto"})
        clearing = subprocess.Popen([BROADWAY, "--world", world.name, "history", "clear", "--json", "--wait-person", "1"], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL)
        asked = False
        for _ in range(100):
            if world.desk({"do": "agents", "action": "questions"}).get("questions"):
                asked = True
                break
            time.sleep(0.1)
        if asked:
            world.desk({"do": "agents", "action": "answer", "with": "yes"})
        out, err = clearing.communicate(timeout=60)
        found = settle(world, lambda f: row(f, "click")["calls"] == 0, seconds=5)
        check("tally", "clearing history empties the count", row(found, "click")["calls"] == 0, (asked, out, err, found))
    finally:
        world.stop()
    sys.exit(ledger.finish())


main()
