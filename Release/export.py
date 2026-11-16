#!/usr/bin/env python3
"""Export one commit's tree to the public repository.

    Release/export.py COMMIT FOLDER --author "Name <…@users.noreply.github.com>"
    Release/export.py COMMIT FOLDER --update --message "Broadway 0.3" --author "…"

Without --update, the tree of COMMIT is written to FOLDER, which must not exist
yet or be empty. FOLDER becomes a git repository on main with one commit.

With --update, FOLDER is a clean clone of the public repository on a branch.
Its tree is replaced by the tree of COMMIT and one new commit is made on that
branch, with --message as its message.

Either way, Tests/public_tree.py from the exported tree checks it first, and
nothing is written or committed unless it passes. The commit is authored and
committed by --author, at --date or now. The author's address has to be a
GitHub noreply one, so no private address goes into the public history.
Nothing is pushed and no remote is added.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUTHOR = re.compile(r"^\s*(?P<name>[^<>]+?)\s*<(?P<email>(\d+\+)?[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?@users\.noreply\.github\.com)>\s*$")
REFUSED_FOLDERS = ("planning", "Prototype", ".context", ".claude")


def git(*arguments, cwd, env=None, capture=True, data=None):
    return subprocess.run(["git", *arguments], cwd=cwd, env=env, capture_output=capture, input=data,
                          text=data is None, check=True)


def clean_env(name, email, date):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update({
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": name,
        "GIT_AUTHOR_EMAIL": email,
        "GIT_COMMITTER_NAME": name,
        "GIT_COMMITTER_EMAIL": email,
    })
    if date:
        env["GIT_AUTHOR_DATE"] = date
        env["GIT_COMMITTER_DATE"] = date
    return env


def stop(words):
    print(f"export: {words}", file=sys.stderr)
    sys.exit(1)


def extract(source, commit, folder):
    archive = subprocess.run(["git", "archive", "--format=tar", commit], cwd=source, capture_output=True, check=True)
    subprocess.run(["tar", "-x", "-C", str(folder)], input=archive.stdout, check=True)


def checked(folder, commit, words):
    present = [name for name in REFUSED_FOLDERS if (folder / name).exists()]
    if present:
        return f"the tree of {commit[:8]} holds {', '.join(present)}, which never goes public"
    found = subprocess.run(check_command(folder, words), capture_output=True, text=True)
    if found.returncode != 0:
        print(found.stdout, end="", file=sys.stderr)
        return f"Tests/public_tree.py refused the tree of {commit[:8]}, nothing was exported"
    return None


def check_command(folder, words):
    command = [sys.executable, str(folder / "Tests" / "public_tree.py"), str(folder)]
    return command + (["--words", words] if words else [])


def commit_tree(folder, message, env):
    git("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--quiet", "--no-verify",
        "-m", message, cwd=folder, env=env)


def default_message(commit, source):
    try:
        version = git("show", f"{commit}:VERSION", cwd=source).stdout.strip()
    except subprocess.CalledProcessError:
        version = ""
    return f"Broadway {version}" if version else "Broadway"


def fresh(args, source, commit, folder, name, email):
    if folder.exists() and (not folder.is_dir() or any(folder.iterdir())):
        stop(f"{folder} exists and is not an empty folder")
    folder.mkdir(parents=True, exist_ok=True)
    extract(source, commit, folder)
    refused = checked(folder, commit, args.words)
    if refused:
        shutil.rmtree(folder)
        stop(refused)

    message = args.message or default_message(commit, source)
    env = clean_env(name, email, args.date)
    git("init", "--quiet", "--initial-branch=main", cwd=folder, env=env)
    git("add", "--all", cwd=folder, env=env)
    commit_tree(folder, message, env)

    count = git("rev-list", "--count", "HEAD", cwd=folder, env=env).stdout.strip()
    said = git("log", "-1", "--format=%an <%ae>%n%cn <%ce>", cwd=folder, env=env).stdout.split("\n")
    if count != "1" or said[0] != f"{name} <{email}>" or said[1] != f"{name} <{email}>":
        stop(f"{folder} did not come out as one commit by {name} <{email}>: {count} commits, {said[:2]}")
    if subprocess.run(check_command(folder, args.words), capture_output=True, text=True).returncode != 0:
        stop(f"{folder} was made, but its check fails")

    files = git("ls-files", cwd=folder, env=env).stdout.count("\n")
    head = git("rev-parse", "--short", "HEAD", cwd=folder, env=env).stdout.strip()
    print(f"exported {commit[:8]} to {folder}: one commit {head}, “{message}”, by {name} <{email}>, {files} files, no remote")


def update(args, source, commit, folder, name, email):
    if not args.message:
        stop("--update needs --message, the new commit's message")
    if not (folder / ".git").exists():
        stop(f"{folder} is not a clone of the public repository")
    env = clean_env(name, email, args.date)
    try:
        top = Path(git("rev-parse", "--show-toplevel", cwd=folder, env=env).stdout.strip()).resolve()
        before = git("rev-parse", "--verify", "HEAD", cwd=folder, env=env).stdout.strip()
        branch = git("symbolic-ref", "--quiet", "--short", "HEAD", cwd=folder, env=env).stdout.strip()
    except subprocess.CalledProcessError:
        stop(f"{folder} has no commit on a branch to add to")
    if top != folder:
        stop(f"{folder} is inside the repository at {top}, not its top")
    if git("status", "--porcelain", "--untracked-files=all", cwd=folder, env=env).stdout.strip():
        stop(f"{folder} has changes of its own: commit or remove them first")

    with tempfile.TemporaryDirectory(prefix="broadway-export-") as scratch:
        staged = Path(scratch)
        extract(source, commit, staged)
        refused = checked(staged, commit, args.words)
        if refused:
            stop(refused.replace("nothing was exported", f"{folder} is unchanged"))

    listed = git("ls-tree", "-r", "-z", "--name-only", commit, cwd=source).stdout
    names = [entry for entry in listed.split("\0") if entry]
    old = [entry for entry in git("ls-files", "-z", cwd=folder, env=env).stdout.split("\0") if entry]
    git("rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", ".", cwd=folder, env=env)
    for entry in old:
        path = folder / entry
        if path.is_symlink() or path.is_file():
            path.unlink()
    for directory in sorted({(folder / entry).parent for entry in old}, key=lambda p: len(p.parts), reverse=True):
        while directory != folder and directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()
            directory = directory.parent
    extract(source, commit, folder)
    git("add", "--force", "--pathspec-from-file=-", "--pathspec-file-nul", cwd=folder, env=env,
        data="\0".join(names).encode())

    now = sorted(entry for entry in git("ls-files", "-z", cwd=folder, env=env).stdout.split("\0") if entry)
    if now != sorted(names):
        stop(f"{folder} did not take the tree of {commit[:8]} exactly: reset it with git reset --hard {before[:8]}")
    if subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=folder, env=env).returncode == 0:
        stop(f"{folder} already holds the tree of {commit[:8]}, no commit was made")
    commit_tree(folder, args.message, env)

    count = git("rev-list", "--count", f"{before}..HEAD", cwd=folder, env=env).stdout.strip()
    parent = git("rev-parse", "HEAD^", cwd=folder, env=env).stdout.strip()
    said = git("log", "-1", "--format=%an <%ae>%n%cn <%ce>", cwd=folder, env=env).stdout.split("\n")
    tree = git("rev-parse", "HEAD^{tree}", cwd=folder, env=env).stdout.strip()
    wanted = git("rev-parse", f"{commit}^{{tree}}", cwd=source).stdout.strip()
    if count != "1" or parent != before or said[0] != f"{name} <{email}>" or said[1] != f"{name} <{email}>" or tree != wanted:
        stop(f"{folder} did not come out as one new commit by {name} <{email}> with the tree of {commit[:8]}")
    if subprocess.run(check_command(folder, args.words), capture_output=True, text=True).returncode != 0:
        stop(f"{folder} was committed, but its check fails")

    head = git("rev-parse", "--short", "HEAD", cwd=folder, env=env).stdout.strip()
    print(f"exported {commit[:8]} to {folder}: commit {head} on {branch} after {before[:8]}, “{args.message}”, by {name} <{email}>, "
          f"{len(names)} files, nothing pushed")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("commit")
    parser.add_argument("folder")
    parser.add_argument("--author", required=True, help='"Name <…@users.noreply.github.com>"')
    parser.add_argument("--update", action="store_true", help="add one commit to a clone of the public repository")
    parser.add_argument("--message", help="the commit message, Broadway VERSION by default, required with --update")
    parser.add_argument("--date", help="the commit date, now by default")
    parser.add_argument("--words", help="a private word list for the check, instead of its default")
    parser.add_argument("--from", dest="source", default=str(ROOT), help="the repository COMMIT is in, this one by default")
    args = parser.parse_args()

    author = AUTHOR.match(args.author)
    if not author:
        stop(f"the author has to be “Name <…@users.noreply.github.com>”, not “{args.author}”")
    name, email = author.group("name"), author.group("email")

    source = Path(args.source).expanduser().resolve()
    try:
        commit = git("rev-parse", "--verify", f"{args.commit}^{{commit}}", cwd=source).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        stop(f"{args.commit} is not a commit in {source}")

    folder = Path(args.folder).expanduser().resolve()
    if folder == source or source in folder.parents:
        stop(f"{folder} is inside the repository it exports from")

    if args.update:
        update(args, source, commit, folder, name, email)
    else:
        fresh(args, source, commit, folder, name, email)


if __name__ == "__main__":
    main()
