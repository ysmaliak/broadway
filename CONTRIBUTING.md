# Contributing

Broadway is made by one person. Help is welcome, and a few things make it land faster.

## Before you start

For anything bigger than a small fix, open an issue first and say what you want to change and why. A short talk saves a pull request that has to be rewritten. The maintainer may decline a change that does not fit the browser, even a good one. Broadway tries to stay quiet and small, and every feature is one more thing to keep working.

Security problems are not issues. Report them privately as [SECURITY.md](SECURITY.md) says.

## Build, run and test

The [README](README.md) has the details. In short:

```sh
./build.sh          # build/Broadway.app
./fresh.sh          # open it in a fresh test world, apart from your own browser
Tests/fast.sh       # the Swift tests, the wording check and the leak check
```

You need macOS 27 and Xcode 27 (Swift 6.4). Run one `Tests/*.py` probe at a time, after `./build.sh`. A probe drives a real app in a hidden test world, and two at once get in each other's way.

## A good issue

- What you did, what you expected, and what happened instead
- The Broadway version (Broadway › About Broadway) and the macOS version
- The page, if a site is involved, and whether Safari shows the same thing
- Logs or pictures with nothing of yours in them that you would not post in public

One problem per issue. An idea is welcome too: say what you are trying to do, not only the button you want.

## A good pull request

- One change, small enough to read from start to end
- `Tests/fast.sh` green, and a test for what you fixed or added
- A title that says what is now true, such as "The tab bar keeps its scroll when a pinned tab closes"
- For a change you can see, a picture or a short film of a test world, before and after
- No new dependencies. Foundation, AppKit and WebKit cover nearly everything

## Rules of the code

These are checked by `Tests/fast.sh` or by review.

- **No code comments.** New code carries no comments and no doc comments. The name of a type, a function or a test says what it does. The older code still has many comments, most of them from Search. Leave them, but don't add new ones. Put the reasons for a change in its commit message or pull request.
- **Tests without structure markers.** No `// Given`, `// When` or `// Then`. A test is short, its name is a sentence that says what holds, and blank lines separate setting up, acting and checking.
- **Wording people read.** `Tests/copy_lint.py` checks every string in `Sources/`. A single sentence takes no full stop, and several sentences keep theirs. No semicolons, no em dashes between words, no exclamation marks, no three typed dots (`…` only when the command asks for more before it acts), no "please", no "successfully", no "(s)". Plain words.
- **Invented data only.** Tests and fixtures use made-up people, `example.com` addresses, the team id `ABCDE12345` and paths under `/Users/someone`. No real names, accounts, repositories, tickets or keys. `Tests/public_tree.py` fails on home folder paths, real email addresses, signing identities, team ids and anything shaped like a key.
- **No requests to real services from a test.** Tests and probes run against local pages and stubs.
- **Windows, menus and popovers stay native.** A design change goes inside them, not around them.

## Review

The maintainer reads every pull request, and it can take a while. A reminder after a couple of weeks is fine. By opening a pull request you agree that your change is released under the [MIT License](LICENSE), like the rest of the code.

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
