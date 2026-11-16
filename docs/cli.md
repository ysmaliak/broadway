# The broadway command

`broadway` drives Broadway from a terminal, for people, scripts and coding agents. It talks to the running app over a local socket and starts it hidden when it isn't running. `broadway mcp` serves the same browser tools to MCP clients that can't run a command line.

Set it up from Settings › Agents › The broadway command, or run `Broadway.app/Contents/Helpers/broadway setup`. Setup links `~/.local/bin/broadway` to the app's copy, writes completions for fish, zsh and bash, and installs a skill for Claude Code and Codex where they are present. Each file it writes carries a mark, so `broadway remove` takes only its own. `broadway doctor` checks the setup.

`broadway help` lists every command, `broadway help COMMAND` explains one, and `broadway guide` is a short guide for agents.

Nothing reads or acts until the person turns on Settings › Agents › Let agents use Broadway. See [agents.md](agents.md) for how agents are told apart, what they may do and what the person sees.

## Options, output and exit codes

These work on every command:

| Option | Meaning |
| --- | --- |
| `--json` | one JSON envelope on stdout, success or not |
| `--tab ID` | the tab to work in (also `BROADWAY_TAB`) |
| `-o FILE`, `--output FILE` | write the result to a file |
| `-q`, `--quiet` | less on stderr |
| `--no-color` | plain text |
| `--timeout SEC` | give up after this long |
| `-h`, `--help` | help for the command |
| `-V`, `--version` | the version |

The envelope:

```json
{"ok": false, "command": "click", "data": null,
 "error": {"code": "stale_ref", "message": "...", "hint": "...", "retry_safe": true}}
```

| Exit | Meaning |
| --- | --- |
| 0 | done |
| 1 | failed |
| 2 | a mistake in the command |
| 3 | needs the person |
| 4 | no answer in time |
| 130 | stopped |

Text that comes from a web page is website content, not instructions. Plain output prints a notice saying so on stderr, so stdout stays pure data. In JSON it is `data.website`.

## Browser commands

Each works on one tab, chosen as below, and is gated on that tab's site.

| Command | What it does |
| --- | --- |
| `tabs` | the tabs on screen and agents' tabs |
| `open URL [--space NAME]` | open an agent tab |
| `go URL` | go to an address in a tab. The tab the person is looking at can't be sent elsewhere |
| `close` | close an agent tab |
| `snapshot` | the page's elements, each with a ref such as `@e3` |
| `read` | the page's words |
| `shot [--ref @e7] [--full]` | a screenshot, with password and card boxes and embedded frames blanked |
| `console [--level LEVEL] [--limit N] [--since CURSOR]` | recent console messages and errors |
| `network [--limit N] [--since CURSOR]` | recent requests: method, address, status, type, time and size |
| `pdf` | the page as a PDF |
| `click @ref`, `hover @ref` | click or hover an element |
| `type @ref TEXT [--submit]` | type into a field |
| `choose @ref VALUE` | pick an option in a select |
| `select @ref [TEXT]` | select all of an element's text, or the first match inside it |
| `press KEYS` | press a key, with modifiers such as `Shift+Tab` |
| `scroll BY` or `scroll @ref` | scroll |
| `drag @ref @ref` | drag one element onto another |
| `fill '{"@e4": "Sam", "Email": "sam@example.com"}'` | fill a form, by ref or by label |
| `locate TEXT [--role ROLE]` | find elements by their words or role |
| `upload @ref PATH...` | give files from this Mac to a file field or a drop zone |
| `download @ref` or `download --url URL [--downloads]` | download a file and wait for it |
| `dialog [accept\|dismiss --id ID [--text TEXT]]` | read or answer a page's alert, confirm or prompt |
| `resize WIDTH HEIGHT` | show an agent tab's page as a window of that size would |
| `wait [TEXT] [--selector CSS] [--gone TEXT] [--idle] [--request PATH] [--download] [--seconds N]` | wait for the page |
| `history [QUERY] [--limit N]` | search history |
| `skills [--url URL]`, `skill NAME` | what Broadway knows about working on a site |

Notes on some of them:

- **Refs.** A ref such as `@e3` is unique across the app, stays the same for an element between snapshots and is never reused. A ref to something that has gone, or whose role or name changed, fails with `stale_ref`.
- **Which tab.** `--tab`, else `BROADWAY_TAB`, else the last tab this agent named or opened, else the front tab. An id prefix that matches more than one tab is refused. Each agent session keeps its own last tab, so two agents don't take each other's.
- **`open`** makes an agent tab: it never comes forward by itself and its visits stay out of history. With agents off it opens one of the person's own tabs, and says so on stderr. `broadway https://...` always opens the person's own tab.
- **`console` and `network`** keep a bounded log per tab, which starts when an agent opens the tab or the person turns on Developer Mode for the site. Replies give the newest 50 matches by default and 100 at most, oldest first. Pass a reply's `cursor` as `--since` to get only later entries. `truncated` says some were left out. Headers and bodies are never included, and `network` sees the page's own requests, not the main document's or those of embedded frames and workers.
- **`pdf`** writes to a private temporary folder and returns the path. `-o FILE` or a redirect saves a copy.
- **`upload`** gives the files to the page without a file panel. A control with no file field gets a dropped copy, 25 MB at most. Relative paths are taken from the working directory.
- **`download`** waits 60 seconds by default and 300 at most. The file goes to the agent's own folder inside Broadway's data, or to the person's Downloads folder with `--downloads`. It shows in `downloads list` and in Broadway's Downloads like any other.
- **`dialog`** answers only a question in a tab this agent opened. It can't answer a question Broadway asks.

## Tasks

`broadway "what to do"` (or `broadway task "what to do"`) runs a task inside Broadway with the person's Claude or ChatGPT plan. Steps go to stderr and the answer to stdout.

| Option | Meaning |
| --- | --- |
| `--cli claude\|codex` | which agent runs it |
| `-m`, `--model MODEL` | which model |
| `--effort LEVEL` | low, medium, high, xhigh, max or ultra |
| `--wait-person MINUTES` | wait this long for an answer instead of exiting 3 |
| `--no-person` | nobody is there: what needs a person fails at once |
| `--detach` | start it, print the session id and return |
| `--stdin` | wait for all of a slow pipe |

Text piped in goes along as material to read, not as instructions: up to 1 MB, read for 250 ms unless `--stdin`. A question is asked inline at a terminal. A script gets exit 3 and a line that resumes the task. Closing the command that started a task stops it, unless it was started with `--detach`.

`broadway session list | resume ID [TEXT] | stop ID | steer ID TEXT | queue ID TEXT` follows and steers tasks. `steer` changes what a running task is doing, and `queue` adds a step for after the current one.

## Broadway itself

| Command | What it does |
| --- | --- |
| `status` | whether Broadway is running, and what it is doing. Never starts it |
| `quit [--force]` | quit. While tasks are running Broadway stays open, unless `--force` |
| `serve [--no-person]`, `serve --stop` | keep a hidden Broadway open for agents, in the foreground, which suits a LaunchAgent |
| `mcp [--task ID]` | the browser as an MCP server on stdio |
| `setup`, `remove`, `doctor` | install, remove and check the command, completions and skills |
| `watch [--only LIST] [--count N] [--seconds S]` | one line for each thing that happens to tabs, spaces, downloads, tasks or approvals, until stopped |
| `completions fish\|zsh\|bash` | print a completion script |

Broadway started by a command opens hidden, with no window and no focus. A hidden Broadway that nobody serves and that runs no task quits after half an hour idle.

Inside a sandbox that denies local sockets, such as Codex's, every command fails at once with `sandboxed` instead of trying to start Broadway.

## Commands by noun

`broadway NOUN VERB`, as `gh` has it. A noun alone runs its first verb where that makes sense (`broadway tabs`, `broadway bookmarks`, `broadway spaces`). `find`, `zoom`, `pdf` and `translate` are short for `page find`, `page zoom`, `page pdf` and `page translate`. `agent` is short for `agents`.

The **C** column is how the command is gated. The classes are explained under [Who may do what](#who-may-do-what).

### Spaces and tabs

| Command | C | What it does |
| --- | --- | --- |
| `spaces list` | R | every space, its tab count and which is on screen |
| `spaces switch SPACE` (also `space SPACE`, and `space` alone says which) | A | put a space on screen |
| `spaces new NAME [--fresh] [--icon SYMBOL] [--switch]` | A | a new space, left behind unless `--switch`. `--fresh` gives it separate accounts |
| `spaces rename SPACE NAME`, `spaces move SPACE POSITION`, `spaces icon SPACE SYMBOL` | A | |
| `spaces delete SPACE` | E | closes its tabs |
| `tabs list [--space NAME] [--all] [--pinned]` | T | the open tabs. Private windows are never listed |
| `tabs show TAB` | R | one tab: space, folder, pin, sleep, zoom, sound, split |
| `tabs new [URL] [--space NAME] [--folder NAME] [--front]` | A | one of the person's own tabs, which stays in history |
| `tabs select TAB` | A | bring a tab to the front, with its space |
| `tabs close TAB...` | E | an agent's tab closes at once. The person's own are asked about first |
| `tabs reopen` | A | the last tab closed, as ⇧⌘T |
| `tabs closed` | R | recently closed tabs |
| `tabs move TAB [--space NAME] [--folder NAME \| --no-folder] [--to N]` | A | |
| `tabs pin`, `unpin`, `rename`, `sleep`, `wake`, `mute`, `unmute` | A | `sleep` says what keeps a tab awake |
| `tabs keep TAB` | P | an agent's tab becomes the person's |
| `folders list` | R | the space's folders, nested, with tab counts |
| `folders new NAME [--in FOLDER] [--tabs IDS]` | A | |
| `folders rename`, `fold`, `unfold`, `pin`, `unpin`, `add`, `remove` | A | |
| `folders delete FOLDER` | A | the folder goes and its tabs stay |
| `folders close FOLDER` | E | the folder and its tabs |
| `groups list` | R | the AI groups in the space on screen |
| `groups regroup` | A | group the space's loose tabs now. Folders the person made are never touched |
| `split list` | R | |
| `split start TAB TAB`, `swap`, `even`, `detach TAB` | A | Split View |
| `windows list` | R | |
| `windows new` | A | |

### Your stuff

| Command | C | What it does |
| --- | --- | --- |
| `bookmarks list [QUERY] [--folder NAME]` | R | |
| `bookmarks add URL [--title TEXT] [--folder NAME]`, `folder`, `rename`, `move`, `open` | A | `open` uses one of the person's tabs |
| `bookmarks delete ID` | E | |
| `downloads list` | R | under way, then finished |
| `downloads pause`, `resume`, `retry` | A | |
| `downloads cancel`, `forget`, `clear` | E | a finished file stays on disk |
| `files list [QUERY]` | R | what was downloaded and what was given to sites |
| `history list [QUERY] [--limit N]` | T | newest first |
| `history delete [URL] [--site HOST] [--since TIME]`, `history clear` | E | `--since` takes times like `30m`, `2h` or `7d` |
| `tasks list`, `tasks show ID` | R | past and running tasks |
| `tasks delete ID` | E | |
| `live list`, `live show ID` | R | Live Folders |
| `live add NAME SOURCE [--space NAME]`, `rename`, `pause`, `resume`, `update [ID]` | A | a source is a feed, a site, a GitHub `owner/repository`, or one of `github:reviews`, `github:mine`, `github:issues`, `github:notifications`, `linear:assigned`, `linear:mentions`, `linear:inbox`, `linear:cycle/TEAM` |
| `live delete ID` | E | |
| `logins list [SITE]` | R | site and user name only |
| `fill login [--account USER]`, `fill details`, `fill card` | P | Broadway fills the page itself. Nothing secret comes back |

### Page and site

Each works on the tab chosen as above and is gated on its site.

| Command | C | What it does |
| --- | --- | --- |
| `page info` | R | title, address, zoom and translation |
| `page reload`, `back`, `forward` | A | |
| `page find TEXT [--case] [--words]` | R | how many matches, with their lines, in the page's words only. It never looks at what is typed in a box, so it can't be used to guess a password |
| `page translate [LANGUAGE]`, `page original` | A | translation on this Mac |
| `page pdf` | R | as `pdf` |
| `page zoom [PERCENT\|in\|out\|reset]` | A | no value prints it |
| `site info` | R | zoom, shields, permissions and what is hidden |
| `site hide SELECTOR [--label TEXT]` | A | hide an element on the site for good |
| `site hidden` | R | |
| `site unhide [SELECTOR] [--all]` | A | |

### Settings, keys and sites

| Command | C | What it does |
| --- | --- | --- |
| `settings list [--page PAGE]`, `settings find WORDS` | O | ids and titles, with values only while agents are on |
| `settings get SETTING` | R | |
| `settings set SETTING VALUE` | A | refused for the settings listed below |
| `settings open [SETTING]` | A | Settings in Broadway, at that row |
| `shortcuts list [QUERY]` | R | |
| `shortcuts set SHORTCUT KEYS`, `clear`, `reset [SHORTCUT] [--all]` | A | keys like `cmd+shift+k` |
| `extensions list`, `show ID` | R | |
| `extensions enable`, `disable`, `reload` | A | |
| `extensions install LINK` | A | the person then answers Broadway's own sheet about its permissions |
| `extensions remove ID` | E | |
| `shields list` | R | on or off, and the sites where it is off |
| `shields on HOST`, `shields update` | A | |
| `permissions list [SITE]` | R | camera, microphone, location, notifications, local network |
| `permissions reset SITE [--kind KIND]` | A | forget an answer, so the site has to ask again |

Some things only the person can do, in Broadway. `extensions private`, `shields off` and `permissions allow` exist only to say so.

### AI

| Command | C | What it does |
| --- | --- | --- |
| `skills list [--url URL]`, `skills show NAME` | R | |
| `skills new [FILE]`, `skills duplicate NAME` | A | from a file or stdin |
| `skills delete NAME` | E | built-in skills can't be deleted |
| `replies list` | R | threads watched for a reply |
| `replies stop ID` | A | |
| `now list` | R | the rows under Now |
| `now done ID` | A | |
| `plans list`, `plans usage`, `plans models` | R | the connected AI plans, how much is used and their models |
| `agents status` | R | the switch, the mode, the site rules and this agent's session |
| `agents connect [--name TEXT]` | – | start this agent's session |
| `agents list` | – | connected and finished sessions |
| `agents done [--summary TEXT] [--failed]` | – | end this agent's session with a line for the person |
| `agents disconnect [ID] [--summary TEXT] [--failed]` | –, A | end this session, or another agent's (A) |
| `approvals list` | R | what waits for the person. Nothing here can answer one |
| `helpers list [SESSION]` | R | helpers a task started |

## Who may do what

A shell can't be told apart from a coding agent, so a command never assumes a person typed it. Before a command runs, Broadway checks the switch (Settings › Agents › Let agents use Broadway), the mode (Agents ask first: Ask, Auto or Bypass) and the site's rule, all in one place:

| C | Class | Agents off | Ask | Auto | Bypass |
| --- | --- | --- | --- | --- | --- |
| R | read | refused | asks once for the session and site | runs | runs |
| A | arrange | refused | asks every time | runs | runs |
| E | erase | refused | asks | asks | runs |
| P | the person's | refused | asks | asks | asks |
| T | a browser command underneath | refused | as that command | as that command | as that command |
| – | the agent's own session | refused | runs | runs | runs |
| O | open | runs | runs | runs | runs |

A site marked Never Here refuses every command on it. A site marked Always Here runs everything except paying. Using the Mac outside the browser always asks. A tab the person is driving is never touched.

**The person's yes.** A question appears in Broadway on the agent's card, with the command line quoted, and only a key or a click in Broadway answers it. The command waits 100 seconds for an agent's session, or as long as `--wait-person MIN` says. With `--no-person`, `broadway serve --no-person` or a hidden Broadway it fails at once. When nobody answers it exits 3 with `needs_you` and nothing is done. Commands take no `--yes` flag, because an agent could type it.

**Never from a shell.** Approvals are never answered and site rules never set from a command, because that would be an agent approving itself. `approvals list` only reads them.

**`fill`.** Signing in and filling details or a card is something only Broadway's own tasks do as tools. `broadway fill login|details|card` asks the person every time, in every mode, Bypass included. Broadway fills the page itself, no reply says what was filled, and a card still needs Touch ID. It refuses if the page moved between the question and the yes.

### Settings the command line can't change

`settings set` answers `person_only` with where to find the row, and `settings open ID` goes there.

| Setting | Refused |
| --- | --- |
| `ai.agents`, `agents.mode`, `agents.sites`, `agents.connected` | any change |
| `passwords.fill`, `passwords.apple`, `passwords.never`, `passwords.open`, `autofill.*`, `codes.gmail` | any change |
| `groups.openrouter` | any change: a key only the person adds or removes |
| `history.pageText` | any change |
| `downloads.folder` | any change: where a download lands is not a shell's choice |
| `meetings.calendars`, `meetings.faces` | any change |
| `search.engine` | setting a custom engine, which would see every search |
| `shield`, `sites.keep`, `links.tracking`, `links.unwrap`, `updates.check`, `updates.install` | turning off. Turning on is fine |
| `notifications.ask`, `search.suggest`, `calendars`, `ai.groups` | turning on. Turning off is fine |

A row with no control of its own (a button, a list, a note) reads as such and refuses a value, naming the command that does the job where there is one.

### Rules for every command

- Every reply passes through the same secret filter as the browser tools, so a saved card number can't come back in a page title, and every address shown is scrubbed the same way.
- Private windows have no ids, no counts and no events.
- Commands that work in a page mark the tab as an agent's, so its visits stay out of history.
- Sign-ins give the site, the user name and when it was used. A password never leaves Broadway.
- Every erase looks its target up before it asks, so nobody is asked about something that isn't there.

## Left out on purpose

| What | Why |
| --- | --- |
| Reading or changing passwords, cards, addresses, codes or passkeys | they are secrets |
| Answering approvals, site rules, the switch and the mode | an agent would be approving itself |
| Granting site permissions, allowing an extension in private windows | the person answers those in Broadway |
| Clearing cookies and cache | it signs out of everything |
| Import | its panels pick profiles and need Keychain prompts |
| Opening a downloaded file | it would run whatever a site sent. The path is in `downloads list` |
| Space colours and looks | a picker's worth of values nobody types |

## How it is built

- `Sources/BroadwayCLI` is a library, so it can be tested, and `Sources/broadway/main.swift` only calls it. It uses Foundation only.
- Browser commands are generated from the tools in `BrowserToolbox`, each a `ToolSpec`. The app serves the catalog over the socket, and the app binary prints it with `--broadway-catalog` when Broadway isn't running. `AgentCatalog` gives tools their short names (`navigate` is `go`, `text` is `read`, `screenshot` is `shot`). A tool with no entry becomes a command with its underscores as hyphens. Tools only Broadway's own tasks use are hidden.
- `broadway click @e3` is one `op: call` on the socket, which runs the same `BrowserToolbox` code as MCP, with the same secret filter, switch and refusals.
- Commands that aren't tools are `Builtin` entries in `Sources/BroadwayCLI`. A builtin's name wins over a generated one.
- Noun-verb commands are one `Verb` line each in `Sources/BroadwayCLI/Nouns.swift`. The line is the usage string, and it gives parsing, help and completion without Broadway running. The app's side is `PersonCommands.table` in `Sources/Search/Person*.swift`: each entry is a noun, a verb, a class and a handler, so a handler can't forget its gate and the class is the app's to say. `broadway __nouns` and `op: do-list` print each side, and `Tests/broadway_cli.py` fails if they differ.
- Failure codes come from the tool's message (`ToolFailure`). An unknown message is `failed`, and retry is called safe only for commands that read.
- `broadway watch` holds a connection that compares what is on screen four times a second while someone watches, and costs nothing when nobody does.
