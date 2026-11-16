#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = Path(os.environ.get("BROADWAY_PRIVATE_WORDS", Path.home() / ".config" / "broadway" / "private-words"))
WALK_SKIPS = {".git", ".build", "build", ".swiftpm", ".context", ".claude", "__pycache__"}

ALLOWED_TEXT = [
    "com.ysmaliak.broadway",
    "Copyright (c) 2026 Yan Smaliak",
]
PUBLIC_REPOSITORY = re.compile(re.escape("github.com/ysmaliak/broadway") + r"(?![\w-])")
EXAMPLE_HOMES = {"me", "you", "someone", "sam", "alex", "x", "a", "user", "USER", "name", "Shared"}
ALLOWED_EMAILS = {"support@broadwaybrowser.com"}
NOTICES = "THIRD-PARTY-NOTICES.md"
EXAMPLE_TEAM = "ABCDE12345"
EXAMPLE_DOMAIN = re.compile(r"(^|\.)(example\.(com|org|net)|example|test|invalid|localhost)$", re.I)
REVERSE_DNS = re.compile(r"(com|org|net|io)\.", re.I)
FILE_SUFFIX = re.compile(r"\.(png|jpe?g|gif|webp|svg|pdf|swift|js|json|html|css|txt|md|py|sh|plist|icns|tiff)$", re.I)

HOME = re.compile(r"/Users/([A-Za-z0-9._-]*[A-Za-z0-9_-])")
EMAIL = re.compile(r"(?<![\w.%+-])([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24})\b")
IDENTITY = re.compile(r"(Developer ID (Application|Installer)|Apple (Development|Distribution)|Mac Developer|3rd Party Mac Developer \w+): [^\"\n()]+\([A-Z0-9]{10}\)")
TEAM = re.compile(
    r"teamid:[A-Z0-9]{10}\b"
    r"|subject\.OU\]? *= *\"?[A-Z0-9]{10}\b"
    r"|\b(DEVELOPMENT_)?TEAM(_ID)? *= *[\"']?(?=[A-Z0-9]*\d)[A-Z0-9]{10}\b"
    r"|\bteam(Identifier|ID)?: *\"(?=[A-Z0-9]*\d)[A-Z0-9]{10}\"")
INVENTED_DATA = re.compile(r"^Tests/([^/]+\.json|\w*Fixtures/.+)$")
PLACES = [
    ("workers.dev address", re.compile(r"\b[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev\b")),
    ("r2.dev address", re.compile(r"\bpub-[0-9a-f]{32}\.r2\.dev\b")),
    ("Cloudflare id", re.compile(r"(?i)\b(account|zone)[_ -]?id[\"']?\s*[:=]\s*[\"']?[0-9a-f]{32}\b|/(accounts|zones)/[0-9a-f]{32}\b")),
    ("App Store Connect key", re.compile(
        r"\bAuthKey_[A-Z0-9]{10}\.p8\b"
        r"|(?i:\b(key[_-]?id|api[_-]?key)\b)[\"']?\s*[:=]?\s*[\"']?(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}\b"
        r"|(?i:\bissuer(?:[_-]?id)?\b)[\"']?\s*[:=]?\s*[\"']?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")),
    ("App Store Connect address", re.compile(r"appstoreconnect\.apple\.com/(apps|access|teams)/[0-9a-f-]{6,}")),
    ("private repository", re.compile(r"\bgithub\.com/[\w.-]+/broadway-[\w.-]+")),
    ("ssh address", re.compile(r"\bssh://[\w.-]+(:\d+)?/")),
]
DOCUMENTS = re.compile(
    r"(?i)\b(app\.)?notion\.(so|site|com)/(p/)?\S*[0-9a-f]{32}\b"
    r"|\bclaude\.ai/(code/)?(artifact|chat|share|project)s?/[0-9a-z-]{8,}"
    r"|\bdocs\.google\.com/(document|spreadsheets|presentation)/d/[\w-]{20,}")
KEYS = [
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+/=]{40,}")),
    ("OpenRouter key", re.compile(r"\bsk-or-v1-[0-9a-f]{20,}")),
    ("Anthropic key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}")),
    ("OpenAI key", re.compile(r"\bsk-(proj-)?[A-Za-z0-9_-]{32,}")),
    ("Groq key", re.compile(r"\bgsk_[A-Za-z0-9]{20,}")),
    ("Google key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}|\bAQ\.[A-Za-z0-9_-]{30,}")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}|\bgithub_pat_[A-Za-z0-9_]{40,}")),
    ("AWS key", re.compile(r"\bAKIA(?!IOSFODNN7EXAMPLE)[0-9A-Z]{16}\b")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{20,}")),
    ("Linear key", re.compile(r"\blin_(api|oauth)_[A-Za-z0-9]{20,}")),
    ("assigned secret", re.compile(
        r"(?i)\b(api[_-]?key|secret|token|password|passwd)[\"']?\s*[:=]\s*[\"'](?=[^\"'\s]*\d)(?=[^\"'\s]*[a-z])(?=[^\"'\s]*[A-Z])[A-Za-z0-9+/_\-]{32,}[\"']")),
]


def tracked(root):
    try:
        listed = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True)
        names = [n for n in listed.stdout.decode().split("\0") if n]
        if names and (root / ".git").exists():
            return names
    except (OSError, subprocess.CalledProcessError):
        pass
    found = []
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in WALK_SKIPS]
        for name in files:
            found.append(os.path.relpath(os.path.join(folder, name), root))
    return sorted(found)


def private_words(path):
    if not path.is_file():
        return []
    words = []
    for line in path.read_text().splitlines():
        word = line.strip()
        if word and not word.startswith("#"):
            bounded = len(word) < 6
            edge = (r"(?<![A-Za-z0-9])", r"(?![A-Za-z0-9])") if bounded else ("", "")
            words.append((word, re.compile(edge[0] + re.escape(word) + edge[1], re.I)))
    return words


def findings(text, words, notices=False, invented=False):
    for allowed in ALLOWED_TEXT:
        text = text.replace(allowed, "")
    text = PUBLIC_REPOSITORY.sub("", text)
    for number, line in enumerate(text.splitlines(), 1):
        for match in HOME.finditer(line):
            if match.group(1) not in EXAMPLE_HOMES:
                yield number, "home path", match.group(0)
        for match in EMAIL.finditer(line):
            address, domain = match.group(0), match.group(2)
            if notices or address in ALLOWED_EMAILS or EXAMPLE_DOMAIN.search(domain) or FILE_SUFFIX.search(domain) or REVERSE_DNS.match(domain):
                continue
            yield number, "email address", address
        for match in IDENTITY.finditer(line):
            if EXAMPLE_TEAM not in match.group(0):
                yield number, "signing identity", match.group(0)
        for match in TEAM.finditer(line):
            if EXAMPLE_TEAM not in match.group(0):
                yield number, "team id", match.group(0)
        for rule, pattern in KEYS + PLACES:
            if pattern.search(line):
                yield number, rule, None
        if not invented and DOCUMENTS.search(line):
            yield number, "private document link", None
        for word, pattern in words:
            if pattern.search(line):
                yield number, "private word", word


def check(root, words):
    problems = []
    for name in tracked(root):
        path = root / name
        if not path.is_file() or path.is_symlink():
            continue
        data = path.read_bytes()
        if b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", errors="replace")
        for number, rule, said in findings(text, words, notices=name == NOTICES, invented=bool(INVENTED_DATA.match(name))):
            problems.append(f"{name}:{number}: {rule}" + (f": {said}" if said else ""))
    return problems


def main():
    parser = argparse.ArgumentParser(description="Fail when a file meant to be public holds something private.")
    parser.add_argument("root", nargs="?", default=str(ROOT))
    parser.add_argument("--words", default=str(WORDS), help="a local list of private words, one per line")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    problems = check(root, private_words(Path(args.words)))
    for problem in problems:
        print(problem)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
