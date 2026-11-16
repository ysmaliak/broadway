#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
SDEF = ROOT / "Broadway.sdef"
NOT_COPY = ROOT / "Tests" / "copy-lint-not-copy.txt"
HOLE = "\u2063"

SKIPPED_FILES = re.compile(
    r"(^|/)(Bench\w*|\w+Bench|\w+Trace|AccessAudit|LayoutWatch|MiniPlayerScripts|ExtensionShims|PopupGesture|SkillsBuiltIn|AIGroupSubjects)\.swift$")

SKIPPED_LINES = re.compile(
    r"\b(log|trace|debugPrint|fatalError|preconditionFailure|precondition|assertionFailure|assert|NSLog|os_log)\("
    r"|\bLog\.|\blogger\.|\.log\(|NSRegularExpression|try Regex|Regex\(|evaluateJavaScript|callAsyncJavaScript"
    r"|NSPredicate|sqlite|CREATE TABLE|SELECT |INSERT |UPDATE |DELETE FROM"
    r"|Passkeys\.failure\(|refuse\(answer|ExtensionShims\.Unsupported\(|\bprompt: #*\"|userAgent|Mozilla/5\.0|Refused\(why:|NSLocalizedDescriptionKey|\bbench\(")

SKIPPED_ARGUMENTS = re.compile(
    r"(forKey|forHTTPHeaderField|systemSymbolName|appendingPathComponent|hasPrefix|hasSuffix|contains|pattern|withExtension"
    r"|forResource|getenv|environment)(:\s*|\(|\[)$|dateFormat = $")

CODE = re.compile(
    r"^[a-z]+://|^[./~]\S|^---\n|\\|\{[^}]*[:;(=][^}]*\}|\}\s*$|\{[^}]*\{|=>|==|&&|\|\||\(\)|\bfunction\b|\bdocument\.\w|\bwindow\.\w|\bvar \w+ ="
    r"|\breturn [\w!(\[\"']+;|\bconst \w|[a-z][A-Z][a-z]+\(|^\s*[-#.@$%]\w|\w=\w|\dpx\b|rgba?\(|[a-z]_[a-z]|\w\.\w+\("
    r"|^\s*<|</\w+>|<\w+[ >/]")

SENTENCE_END = re.compile(r"(?<=[\w”’\")" + HOLE + r"])[.?!](?=[\"”’)]?\s+\S)")
ABBREVIATIONS = re.compile(r"\b(e\.g|i\.e|etc|vs|No|St|Dr|Mr|Mrs|Ms|a\.m|p\.m)\.$")
OPENS_ONLY = re.compile(
    r"^((Show|Manage) .+|Open|Options|Downloads|Files|Passwords|Site Controls|Chrome Web Store|Bring Things Over|Bring Them Over"
    r"|Another Browser|Sidebar Settings|Hidden on This Site|Sign In|Single Sign-On)…$")
RULES = ["full stop after one sentence", "no full stop after the last of several sentences", "three dots", "semicolon",
         "em dash", "ellipsis on a command that only opens", "exclamation mark", "please", "successfully", "(s)"]


class Literal:
    def __init__(self, path, line, text):
        self.path = path
        self.line = line
        self.text = text

    def place(self):
        return f"{self.path}:{self.line}"

    def shown(self):
        return self.text.replace(HOLE, "\\()").replace("\n", "\\n")


def literals(text):
    found = []
    i = 0
    line = 1
    n = len(text)
    joined = False
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            line += text.count("\n", i, end)
            i = end
        elif c == '"' or (c == "#" and re.match(r'#+"', text[i:i + 8])):
            start = line
            opened = i
            value, i, crossed = literal(text, i)
            line += crossed
            if joined and found:
                found[-1] = (found[-1][0], found[-1][1], found[-1][2] + value, i)
            else:
                found.append((start, text[text.rfind("\n", 0, opened) + 1:opened], value, i))
            ahead = re.match(r'\s*\+\s*(?=#*")', text[i:])
            joined = bool(ahead)
            if ahead:
                line += ahead.group(0).count("\n")
                i += ahead.end()
        else:
            i += 1
    return found


def literal(text, i):
    hashes = 0
    while text[i] == "#":
        hashes += 1
        i += 1
    multi = text.startswith('"""', i)
    quote = '"""' if multi else '"'
    i += len(quote)
    close = quote + "#" * hashes
    escape = "\\" + "#" * hashes
    out = []
    crossed = 0
    n = len(text)
    while i < n:
        if text.startswith(close, i):
            i += len(close)
            break
        if text.startswith(escape, i):
            j = i + len(escape)
            if j < n and text[j] == "(":
                depth = 0
                k = j
                while k < n:
                    if text[k] == '"':
                        _, k, more = literal(text, k)
                        crossed += more
                        continue
                    if text[k] == "(":
                        depth += 1
                    elif text[k] == ")":
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    elif text[k] == "\n":
                        crossed += 1
                    k += 1
                out.append(HOLE)
                i = k
                continue
            if j < n and text[j] == "\n":
                crossed += 1
                i = j + 1
                while i < n and text[i] in " \t":
                    i += 1
                continue
            if j < n and text[j] == "u" and text.startswith("{", j + 1):
                end = text.find("}", j)
                try:
                    out.append(chr(int(text[j + 2:end], 16)))
                except ValueError:
                    pass
                i = end + 1
                continue
            if j < n:
                out.append({"n": "\n", "t": "\t", "r": "\r", "0": ""}.get(text[j], text[j]))
                i = j + 1
                continue
        if text[i] == "\n":
            crossed += 1
            if not multi:
                break
        out.append(text[i])
        i += 1
    value = "".join(out)
    if multi:
        rows = value.split("\n")
        if rows and not rows[0].strip():
            rows = rows[1:]
        if rows and not rows[-1].strip():
            indent = len(rows[-1])
            rows = [row[indent:] for row in rows[:-1]]
        value = "\n".join(rows)
    return value, i, crossed


def plain(text):
    return text.replace(HOLE, "x")


def refusal(text, before):
    shown = plain(text).strip()
    if len(shown) < 2 or not re.search(r"[A-Za-z]{2}", shown):
        return "no words"
    code = CODE.search(shown)
    if code:
        return f"code {code.group(0)!r}"
    argument = SKIPPED_ARGUMENTS.search(before)
    if argument:
        return f"argument {argument.group(0)!r}"
    words = re.findall(r"[A-Za-z’']+", shown)
    if " " not in shown:
        return None if re.fullmatch(r"[A-Z][a-z]+(…|\.\.\.|[.!?:])?", shown) else "one token"
    if text.lstrip().startswith(HOLE) and re.search(r"[a-z]{2}", text):
        return None
    if shown[0].islower() and not re.search(r"[.?!…]$", shown) and len(words) < 4:
        return "short and lowercase"
    return None


def sentences(shown):
    parts = []
    start = 0
    for match in SENTENCE_END.finditer(shown):
        head = shown[start:match.end()]
        if ABBREVIATIONS.search(head):
            continue
        parts.append(head)
        start = match.end()
    rest = shown[start:].strip()
    if rest:
        parts.append(rest)
    return parts


def findings(text):
    shown = text.strip()
    piece = text[:1].isspace() or text[-1:].isspace()
    found = []
    if "..." in shown:
        found.append("three dots")
    if re.search(r";(\s|$)", shown):
        found.append("semicolon")
    if re.search(r"\s—|—\s", text):
        found.append("em dash")
    if OPENS_ONLY.search(shown):
        found.append("ellipsis on a command that only opens")
    if re.search(r"\w!(\s|$|[\"”’])", shown):
        found.append("exclamation mark")
    if re.search(r"\bplease\b", shown, re.I):
        found.append("please")
    if re.search(r"\bsuccessfully\b", shown, re.I):
        found.append("successfully")
    if "(s)" in shown:
        found.append("(s)")
    for paragraph in [p.strip() for p in shown.split("\n") if p.strip()]:
        count = len(sentences(paragraph))
        stopped = re.search(r"\.[\"”’)]?$", paragraph) and not paragraph.endswith("...") and not ABBREVIATIONS.search(paragraph)
        carried = re.search(HOLE + r"\s+[A-Z][a-z]+ [a-z]", paragraph)
        if count == 1 and stopped and not piece and not carried and "\n" not in shown:
            found.append("full stop after one sentence")
        if count > 1 and not piece and re.search(r"[A-Za-z0-9\"”’)" + HOLE + r"]$", paragraph) and not paragraph.endswith(HOLE):
            found.append("no full stop after the last of several sentences")
    return list(dict.fromkeys(found))


def not_copy():
    if not NOT_COPY.exists():
        return set()
    return {row for row in NOT_COPY.read_text(encoding="utf-8").split("\n") if row}


def collect(dropped=None):
    every = []
    excused = not_copy()
    for path in sorted(SOURCES.rglob("*.swift")):
        relative = str(path.relative_to(ROOT))
        if SKIPPED_FILES.search(relative):
            continue
        text = path.read_text(encoding="utf-8")
        rows = text.split("\n")
        for line, before, value, _ in literals(text):
            source = rows[line - 1] if line <= len(rows) else ""
            found = Literal(relative, line, value)
            why = "line" if SKIPPED_LINES.search(source) else refusal(value, before)
            if why is None and found.shown() in excused:
                why = "listed in copy-lint-not-copy.txt"
            if why is None:
                every.append(found)
            elif dropped is not None and len(re.findall(r"[A-Za-z’']{2,}", plain(value))) >= 3:
                dropped.append((found, why))
    if SDEF.exists():
        for number, row in enumerate(SDEF.read_text(encoding="utf-8").split("\n"), 1):
            for value in re.findall(r'description="([^"]*)"', row):
                every.append(Literal("Broadway.sdef", number, value.replace("&apos;", "'").replace("&amp;", "&")))
    return every


def main():
    parser = argparse.ArgumentParser(
        description="Lists the words a person reads in Sources/ and Broadway.sdef, and flags the ones that break the mechanical "
        "copy rules: a single sentence ending in a full stop, several sentences without a closing one, three typed dots, "
        "a semicolon, an em dash between words, an ellipsis on a command that only opens a page, a window, a popover or a site "
        "(Show…, Manage… and the ones named in OPENS_ONLY), an exclamation mark, please, successfully and (s). Words that are not for a person, such as what "
        "a model is told, are listed one per line in Tests/copy-lint-not-copy.txt.")
    parser.add_argument("--all", action="store_true", help="print every string, not only the flagged ones")
    parser.add_argument("--dropped", action="store_true", help="print the strings of three words or more that were left out, and why")
    parser.add_argument("--count", action="store_true", help="print only the counts, by rule")
    parser.add_argument("paths", nargs="*", help="only files whose path contains one of these")
    options = parser.parse_args()

    def wanted(found):
        return not options.paths or any(p in found.path for p in options.paths)

    dropped = [] if options.dropped else None
    every = [found for found in collect(dropped) if wanted(found)]
    if options.dropped:
        for found, why in dropped:
            if wanted(found):
                print(f"{found.place()}\t{why}\t{found.shown()[:200]}")
        return 0
    if options.all:
        for found in every:
            print(f"{found.place()}\t{found.shown()}")
        return 0
    flagged = [(found, findings(found.text)) for found in every]
    flagged = [(found, broken) for found, broken in flagged if broken]
    if not options.count:
        for found, broken in flagged:
            print(f"{found.place()}\t{', '.join(broken)}\t{found.shown()}")
    print(f"{len(every)} strings, {len(flagged)} flagged", file=sys.stdout if options.count else sys.stderr)
    if options.count:
        for rule in RULES:
            print(f"{sum(1 for _, broken in flagged if rule in broken)}\t{rule}")
    return 1 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
