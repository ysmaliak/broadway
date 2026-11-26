# Hooks

A hook is a small program of your own that decides something Broadway would otherwise decide by its own rules: where a link from another app opens, where a finished download goes, and how a site's request for the camera, microphone, location or notifications is answered. A hook can also run every so many minutes.

You add hooks in Settings › General › Developer › Hooks, at the foot of the page. `Add Hook…` asks what the hook is for, then `Choose Program…` opens the Mac's own open panel. Choosing the file is your approval. Each hook has a switch, the result of its last run, and a menu with `Show in Finder`, `Approve Again` where it applies, and `Remove`.

`broadway hooks list` shows each hook's event, program, switch and last result. Nothing else in the command, MCP, a page or an extension can add a hook or switch one on.

## The file

Hooks are kept in `hooks.json` in Broadway's own folder, beside its other settings files:

```json
{
  "hooks" : [
    {
      "event" : "link",
      "id" : "0B6F3A52-6C1E-4A57-9D0B-2E61D7F0C8A1",
      "on" : true,
      "program" : "/Users/someone/bin/sort-links"
    },
    {
      "event" : "permission",
      "hash" : "9f2c…",
      "id" : "5D1C8E2B-3F7A-4B60-8C2D-7A9E0F4B1D36",
      "on" : true,
      "program" : "/Users/someone/bin/meeting-sites"
    },
    {
      "event" : "timer",
      "id" : "C3A7E91F-2B4D-4E58-A6F0-1D8B5C2E7F49",
      "minutes" : 15,
      "on" : true,
      "program" : "/Users/someone/bin/tidy"
    }
  ],
  "version" : 1
}
```

The file is written whole or not at all. A hook this Broadway doesn't understand, such as an event from a later version, is kept as it is and never run. `off` holds the reason when Broadway switched a hook off itself.

## A call

Broadway starts the program by its path, by itself: no shell, no arguments, a small fixed environment (`HOME`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LANG`, `TMPDIR`) and your home folder as its working folder. It writes one JSON object to the program's standard input, with `event`, `version` (1) and the event's own fields, and then closes it.

The program answers with one JSON object on standard output, at most 64 KB. An empty answer, `{}`, or an exit code other than 0 means nothing, and Broadway goes on as if there were no hook. An answer Broadway can't read, or one that names a space, app or folder that doesn't exist, also counts as nothing, and the hook's row says what was wrong. The last 2 KB of what the program writes to standard error is kept for its row.

`link` and `permission` hooks decide while you wait, so they get one second. `download` and `timer` hooks get thirty seconds. A program still running then is stopped, with anything it started. When several hooks take one event they are asked in the list's order, and the first answer that isn't nothing is used.

## The four events

### `link`

A link arrives from another app, and your own link rules in Settings › Links found no rule for it. Your rules always win over a hook, and a hook wins over the default. Holding ⌥ as the link arrives still lets you choose.

In:

```json
{"event": "link", "version": 1, "url": "https://docs.example.com/guide?id=7", "from": "com.example.mail", "space": "Work"}
```

`from` is the sending app's identifier, empty when macOS doesn't say. `space` is the space in front, empty when spaces are off.

Out, one of:

```json
{"space": "Reading"}
{"private": true}
{"app": "com.example.reader"}
{}
```

### `download`

A download has finished and is in its place.

In:

```json
{"event": "download", "version": 1, "file": "/Users/someone/Downloads/invoice-0042.pdf", "site": "billing.example.com", "type": "application/pdf", "size": 48213}
```

Out:

```json
{"folder": "~/Documents/Invoices"}
```

The folder must already exist and be inside your home folder. A file of the same name there is never replaced: the download gets a number instead. Downloads you place yourself, with Settings › General › Ask where to save, don't reach a hook.

### `permission`

A site asks for the camera, the microphone, your location or to send notifications, and you have no answer kept for that site.

In:

```json
{"event": "permission", "version": 1, "site": "https://meet.example.com", "wants": ["camera", "microphone"]}
```

`wants` holds `camera`, `microphone`, `location` or `notifications`.

Out:

```json
{"answer": "allow"}
{"answer": "deny"}
{}
```

The answer is used for that one request and is not kept as the site's answer, so the site asks again next time. Nothing means Broadway asks you as usual.

### `timer`

Every so many minutes while Broadway runs, five at least.

In:

```json
{"event": "timer", "version": 1, "time": "2026-11-17T09:30:00Z", "minutes": 15}
```

Nothing it writes is read.

## What a hook can never do

1. Only you add a hook or switch one on, in Broadway's own window. Never an agent, never the `broadway` command, never MCP, never a page, never an extension. The command can list hooks and nothing more.
2. A hook never touches agents. It never answers an agent's approval, never changes an agent's mode or a site rule for agents, and never runs for anything that happens in an agent's tab.
3. A hook never answers a certificate question, a client certificate question, a saved login, a card, a code, a passkey, a download's "ask first" question, or "Leave this page?".
4. Nothing in a private window reaches a hook. No event, no address.
5. What a page controls is data. An address, a file's name, a site's name: all of it reaches the program as JSON on its standard input, never as an argument, never through a shell and never in an environment variable.
6. The program is started by itself, by its path, with no shell, no arguments, a small fixed environment and your home as its folder.
7. A `permission` hook is bound to the program as it was when you approved it. Broadway keeps a hash of the file. If the file has changed, the hook doesn't run, and its row says `Changed since you approved it` with `Approve Again` in its menu. Broadway runs a copy of exactly the bytes it checked, so the file can't be swapped between the check and the run. A permission program that looks up its own path finds that copy, in a folder of Broadway's own, and not the file you chose. Other kinds of hook run as the file stands.
8. A hook can only narrow or choose among what you could do by hand. It can't allow what Settings forbids for every site, such as notifications when Settings › Privacy turns them off, and it can't answer for a site you have already answered for.
9. A hook can't hold Broadway up. After its second, or its thirty, Broadway does what it would have done with no hook. Three time-outs, crashes or failed starts in a row switch the hook off, and its row says why. Turning it back on starts the count again.
10. In a test world hooks come from that world's own file and run only programs inside that world's folder.

Programs on your Mac that can already write your files can also write `hooks.json`, the same as any of Broadway's settings files. Broadway doesn't sign the file.

## Two examples

A link hook in Python that sends documents to a space called Reading, and everything else on:

```python
#!/usr/bin/env python3
import json, sys

link = json.load(sys.stdin)
if "docs." in link["url"] or link["url"].endswith(".pdf"):
    print(json.dumps({"space": "Reading"}))
```

A permission hook in shell that lets one meeting site use the camera and microphone and leaves every other question to you. The site's name arrives as JSON data and is only compared, never run:

```sh
#!/bin/sh
request=$(cat)
case "$request" in
  *'"site":"https://meet.example.com"'*) echo '{"answer": "allow"}' ;;
  *) echo '{}' ;;
esac
```
