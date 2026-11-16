#!/usr/bin/env python3
"""The window shell's motions on the 120 Hz screen: motion_120's films plus
the column folding away and back (⌘S) and the sidebar moving sides.

Build first (`./build.sh`), then `python3 Tests/shell_120.py --out DIR
[--only a,b] [--runs N] [--app PATH]`, with motion_120's options.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_120 as m  # noqa: E402

SHELL = ["tab-switch", "tab-open", "tab-close", "field-in", "field-out", "load", "peek-in", "peek-out",
         "split-open", "split-close", "link-in", "link-out", "toast", "column-fold", "column-unfold"]
plain = m.motions


def motions(made):
    table = plain(made)
    fold = lambda: m.press(1, "s", "cmd")
    table.append(("column-fold", fold, 1.4, None))
    table.append(("column-unfold", fold, 1.4, None))
    return table


m.motions = motions
m.PARTNERS.update({"column-fold": "column-unfold", "column-unfold": "column-fold"})

if __name__ == "__main__":
    if "--only" not in sys.argv:
        sys.argv += ["--only", ",".join(SHELL)]
    m.main()
