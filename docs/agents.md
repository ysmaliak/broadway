# Agents in Broadway

Outside agents (Claude Code, Codex, Cursor, a script) use Broadway through the `broadway` command or `broadway mcp`. Each one is an **agent session**. Broadway shows every session in an Agents area at the foot of the sidebar, with a face, a name, what it is doing and its tabs. The person can watch an agent work, take over a tab and hand it back. The agent runs outside Broadway, and Broadway shows it working.

Nothing works until the person turns on Settings › Agents › Let agents use Broadway. The command reference is [cli.md](cli.md).

## Sessions

### Telling one agent from another

Each `broadway` run is a new process, often in a new shell, so neither the connection nor an exported variable can hold a session. Instead the command sends its **agent ancestor** with every request:

- It walks up from its parent process, passing over shells and launchers (`zsh`, `bash`, `fish`, `env`, `sudo`, `timeout`, `xargs`, `tmux`, `npx` and the like), and stops at the first other process. It sends that process's id, its start time and its name. The start time means a reused process id can't join an old session.
- A `node`, `bun` or `deno` process running Claude Code's, Codex's, Gemini CLI's or opencode's script is named for the agent, not the interpreter.
- The name shown comes from the program: `claude` is Claude Code, `codex` is Codex, `cursor` is Cursor, and so on. Anything else is shown by its own name.
- `BROADWAY_AGENT_NAME` sets the name. `BROADWAY_AGENT` names a session outright, for a script that wants several sessions from one shell.
- Every request also carries the agent's folder: its working directory, reduced to the git root above it. A git worktree counts as the repository it belongs to. The command does the reduction, so Broadway never looks into the person's folders itself. `BROADWAY_SPACE` names a space for the session.
- `broadway mcp` holds its connection open, so the connection is the session. Its name comes from the client's name in MCP's `initialize`.

A person typing `broadway` at their own terminal gets a session named for the terminal app, and a short script gets one named for its program, such as Python. These are the person's own sessions. Every program found this way that isn't Claude Code, Codex, Cursor, opencode or Gemini CLI counts as one. A session of the person's ends only after 20 minutes without a command, never because its process exited, and at the end a tab they have looked at becomes theirs. An agent found by its process ends when that process exits.

### Life of a session

- **Start.** `broadway agents connect [--name NAME]` starts the session at once. Otherwise the first command that opens or works in a tab starts it, and other commands only join a session that exists.
- **Between steps.** While nothing is at work in its tabs, a session's line reads "Thinking". It never says "Waiting", which read as waiting for the person.
- **Finished turn.** When the agent's turn ends, its card reads finished, with the tick face and the last thing it did, such as "Finished after reading example.com", or the agent's own `--summary`. The session stays live: its tabs stay as they are and its next command makes the same card work again. Broadway learns it from, in order of trust:
  - the agent's **Stop hook**, which runs `broadway agents idle --hook claude` (or `codex`) with the hook's event on stdin. `broadway setup claude` and `broadway setup codex` add it, and Broadway runs `broadway setup claude codex cursor opencode gemini` itself when the person turns agents on, and once at the first launch that finds agents already on, and later for an agent it finds for the first time. That run also puts the skill where Cursor, opencode and Gemini CLI read it, for those that are installed. They get no hook. When nothing is at `~/.local/bin/broadway`, that run is `broadway setup command claude codex cursor opencode gemini`, so the hook has a command to call. It links nothing while Broadway runs from its disk image or a download folder, since that copy goes away. The refresh at every launch never adds one, it only brings Broadway's own entries up to date. A Stop with background tasks or scheduled wakeups still pending is not a finished turn.
  - `broadway agents idle [--summary TEXT]`, for an agent or script that says so itself.
  - an MCP connection that shares a session with the agent's commands closing.
  - **Quiet time.** With no hook, after 2 minutes with no request, no call in flight, no question up, no download under way and no tab at work, the line reads "Idle", or "Idle after reading example.com", with the sleeping face.
  A question up for the person always wins: such a session reads "Needs you", never finished or idle.
- **End.** A session ends on `broadway agents done` or `broadway agents disconnect`, on the agent's **SessionEnd hook**, when its own MCP connection closes, when its ancestor process exits (for a session keyed by the agent's session id, when the `claude`, `codex`, `cursor` or `windsurf` process its commands came from exits), or after 20 minutes with no request, no call in flight, no tab at work and no question up for the person. A tab at work or a question holds the end for 20 minutes more at most, so a stuck one can't keep a session forever. `--summary TEXT` leaves a line for the person, up to 200 characters, and `--failed` marks it as not finished. `agents done` wins over a finished turn.
- **The folded header** counts sessions as waiting for you, working (which includes Thinking), done (which includes a finished turn), failed and idle. A finished agent never counts as working or as needing the person.
- **After the end.** However the session ended, its tabs close, in every space, whether the person looked at them or not. Three things change that:
  - The tab the person is looking at as the session ends becomes theirs, as `broadway tabs keep` makes it, and is never closed under them.
  - The agent hands over what the person should see: `broadway tabs keep TAB` before the end, or `agents done --keep` for all of its tabs. `--keep` asks the person once, naming how many tabs and which spaces. Yes hands them all over. No, or no answer in time, hands nothing over and they close as with plain `done`. `--close` is still accepted and changes nothing.
  - A tab with a form not sent, a download under way, sound playing or a window it opened still open is spared. It is checked again every 30 seconds and closes once the reason is gone. A tab still spared 20 minutes after the end becomes the person's.
  `agents done` says what it closed, what it kept and why, and what became the person's. A `--tab` given to `agents done` is ignored. Once no tab is left the session leaves the card. The SessionEnd hook ends the session for every `reason` Claude Code sends (`clear`, `resume`, `logout`, `prompt_input_exit`, `other`) and for Codex, whose `reason` is always `other`. The hook answers at once and the tabs close in Broadway after it.
- **Again.** A request from the same agent after its session ended starts a new session. A command that names one of the old tabs, or that works in no tab of its own, is refused once with `session_ended`, such as "Your Broadway session ended after 20 minutes without a command, and its tabs closed", and the hint to open the page again. It never acts on a tab that became the person's. A tab still spared when the agent comes back is its own again.

Two sessions of the same program are numbered, such as "Claude Code 2".

### Tabs are the agent's choice

Each session has a **current tab**: the last tab it opened or named with `broadway tab ID`. A command without `--tab` works there, so two agents working at once don't take each other's tab. `open` always opens another tab, which becomes the current one. `go` moves the current tab. Broadway sets no limit and forces no reuse: the agent keeps as many tabs as the work needs, and closes the ones it is done with (`close`, `close --others`, `close --all`). `open` says when the session already has a tab on the same address.

A link or a script in an agent's tab that opens a new window gives a tab of the same session, behind the person's and out of history, never one of the person's. The action's answer names it, and it becomes the current tab only when the agent switches to it. If the person marked that site Never Here, the new tab closes and the answer says so.

Subagents of one agent share its session and its current tab, so each passes `--tab` (or sets `BROADWAY_TAB`) with the id its own `open` gave.

### The session is who asks

When a command needs the person's yes, the session is what asks. The question shows on that session's tab, with the command quoted and the agent's name, and its face waves until the person answers. A yes for reading a site holds for the rest of the session. If Broadway is in the background, a notification says which agent needs the person.

A command waits 100 seconds for the answer, which is under Claude Code's default two-minute Bash timeout. Over MCP a connection waits 600 seconds when the client is Claude Code and shows progress, and 15 seconds for other clients, and says at once in the client that it waits for the person. `--wait-person MIN` waits longer and `--no-person` fails at once. When the wait runs out the command exits 3 with `needs_you`, nothing is done, and the question stays up. Each step of a `batch` passes the same checks one by one.

A yes that arrives after the agent stopped waiting is recorded, so the agent's next try goes through. A yes to reading a site or using tabs holds for the rest of the session. A yes to sending, paying, deleting or uploading becomes a pass for that one act, on that site and that target, which the session's next identical step uses within 120 seconds and which is then gone, so one yes never covers a second, different send. A late yes never acts by itself.

### Handing a tab to the person

`broadway handoff REASON` is the explicit form of taking over. It puts a card on the agent's tab with the reason, such as "Solve the captcha", tells the person, and waits until they press Done, close the card, or take the tab and hand it back. Then it answers with what changed while they had it. `--optional` adds Skip, which answers `skipped: true`. It passes the same tab gate as any command, never brings the tab forward by itself, and fails with `needs_you` when the person doesn't answer in time (300 seconds by default, 900 at most).

### Asking the person a question

`broadway ask "Which account?" --choice Work --choice Personal`, or the MCP tool `ask` from `more_tools`, puts a question on the agent's own tab. The card reads as the agent's: its face, "Claude Code asks", the question and the choices, with Not Now to close it. The session's row says "Claude Code needs you" with the question, and a press goes to the tab, as for any question. Without a tab of its own the card shows with no tab, never on one of the person's.

- **Limits.** Two to nine choices of 40 characters at most, a question of 200 at most, one question up at a time for a session (`question_open`), and six an hour (`too_many_questions`).
- **Waiting.** As `handoff`: 300 seconds by default and 900 at most, with the same progress over MCP, then `needs_you`.
- **The answer** is the words of the choice picked, exactly. A card closed without a pick answers so, plainly, not as an error. Nothing typed by the person is passed back.
- **Never an approval.** A pick opens nothing the gate would have asked about, and the gate still asks its own question when the agent acts. No mode answers a question, Bypass included.
- **Only the agent asks.** The words come from the agent's call. Nothing a page says raises a question, and the tool tells agents never to ask because a page told them to.

An agent fills a form with saved details through `broadway fill`, which asks the person every time.

## What the person decides

All of these are in Settings › Agents, and none of them can be changed from the command line:

- **Let agents use Broadway.** Off until the person turns it on.
- **Agents ask first: Ask, Auto or Bypass.**
  - Ask asks before tabs, the Mac, signing in, sending, paying, deleting and uploading.
  - Auto asks before the Mac, sending, paying, deleting and uploading.
  - Bypass never asks, except before using the Mac. Captchas and passkeys still stop for the person.
- **Sites.** A site can be marked Always Here or Never Here from a question's answer. Never Here refuses every act on it. Always Here lets everything through except paying.
- **Connected agents**, and **the broadway command** for setting it up.

[cli.md](cli.md#who-may-do-what) lists how each command is gated. The MCP tools for spaces, folders, bookmarks, live folders and settings take the same path as their commands, so each is gated exactly as its command is.

## The Agents area

The area is a card at the foot of the sidebar, below the tabs. It appears when the first agent connects and goes when the last one leaves. Its own row is shaped like a tab row: up to three faces where a row's icon would be, the title "Agents", and a line under it saying what is going on, such as "2 working" or "Claude Code · Typing on github.com".

- **Folded by default.** A press on the row unfolds the card, and the choice holds for the whole app. Folded, the card hides every agent.
- **One agent.** Unfolded, its tabs sit straight under the row as rows, indented as in a folder, with a live dot while the agent is acting in a tab.
- **Several agents.** Each gets a heading, and the heading is also the tab the agent is on. It shows the agent's face and name, and under the name what the agent is doing and where, such as "Reading · Release notes". The tab is the one that asks, else the one the agent is acting in, else the last one it acted in. An agent at rest between turns reads "Idle" with its tab's name, and one that has finished, kept on the card by a tab that is spared, shows its closing words.
- **An agent's fold.** The agent's other tabs fold under its heading, and every agent starts folded. A press on the heading shows its tab. A press on the chevron beside the name opens or shuts the fold. That is the split a tab leading a stack has in the tab list, where the row selects and its small arrow folds. An agent with one tab has no chevron. Folds are not remembered across launches.
- **The count.** A folded heading shows how many tabs are inside its fold. It is the same count a folded folder shows in the tab list, at the same place. An open fold shows no count, and neither does one with nothing in it.
- **Closing.** On hover a heading's count gives way to the sidebar's close button, which closes all of that agent's tabs, whether the agent is still at work or has finished and left spared tabs behind. Each tab row in a fold has its own. With one agent the button is on the card's row.
- **Needs you.** Nothing opens by itself. The card's row says "Claude Code needs you" with the question. With several agents the asking agent's heading turns amber, shows the question and becomes the tab that asks. A press on either goes to that tab.
- **Height.** The card takes at most 40 percent of the sidebar. Past that its list scrolls, with the agent that needs the person, or the fold just opened, kept in view. Four folded agents fit without scrolling in a sidebar of ordinary height. The tab list ends above the card.
- **Which space.** A window's card lists only the agent tabs of the space it shows. A session with tabs in two spaces shows in each with the tabs of that space, and its heading there is one of that space's tabs. A session with no tab yet shows in its own space, below. While an agent in another space needs the person, that space's icon at the foot of the sidebar carries a small dot in the asking colour.
- **Motion.** The card makes room and closes it on the cover spring, fading in and out as it does. A heading that arrives fades in while it drops into place, and one that leaves fades out. Opening or shutting a fold rides the same spring, with the chevron turning. The heading's second line rolls when the agent moves to another tab or asks, and the face of an agent that starts to need the person hops once. A switch of space draws the other space's card at once. Under Reduce Motion nothing travels: what arrives or leaves only fades, and words change at once.
- **Menu.** A session's menu has Keep Tabs, Close Tabs, Move to Space when there is another space, and Disconnect while it is connected. Disconnecting ends the session from Broadway's side and closes its tabs as any end does, and the agent's next command starts a new one.

A session's tabs live only in the area, not in the tab list. A tab of the person's that an agent works in stays where it is, with a small face on its row.

### The session's space

With spaces on and more than one of them, each session has a space of its own, chosen when it connects. The first rule that fits wins:

1. **Asked.** `BROADWAY_SPACE` names a space. One that doesn't exist is passed over.
2. **Learned.** The space this folder's sessions were last moved to or opened in with `--space`. Broadway keeps the last 200 folders in its settings. A folder whose space was deleted goes on to the next rule.
3. **Named.** A space whose name is one of the folder path's parts, ignoring case. Only the parts below the home folder count. A name of several words matches a part with spaces, dashes or underscores between them, so Side Projects matches `side-projects`. When two spaces match, neither does.
4. **In front.** The space on screen when the session connected, as before.

- **Opening.** An agent's `open` opens in the session's space, even with another space on screen. The tab stays behind there, as agent tabs in another space always have. A popup follows its opener. `open URL --space NAME` opens in that space instead, makes it the session's space, and teaches it to the folder.
- **Moving.** The session's menu on the card has Move to Space, which moves the tabs the card lists and the session with them. `broadway tabs move TAB --space NAME` moves one tab. An agent's tab can't be dragged or moved from a tab's own menu, as before. Every move of an agent's tab to another space, by any of these paths, takes the session's space with it, and the folder learns it. A tab of a session that already ended still teaches its folder. A private window never teaches.
- **Telling.** `open`'s answer carries `space`, with the space's name, why it was chosen and how to change it. The first open of a session, and the first after its space changes, also says so in words, with how to change it: "In Personal, matching ~/Projects/personal. Run broadway open URL --space NAME to pick another and keep it for this folder." Broadway picks a sensible space and makes another easy to choose. It refuses only a space that doesn't exist, with the names of those that do.
- With one space, or spaces off, nothing here applies and an agent opens in the space on screen.

## Watching an agent

- **Opening a tab.** Pressing a row shows the tab, switching space if needed. Showing a tab doesn't stop the agent.
- **The pointer.** When the agent clicks, types, presses, scrolls or hovers, Broadway draws its pointer over the page, in the agent's colour with its name: it moves to each target, rings on a click and outlines a field while typing. It is drawn by Broadway above the page, so the page can't see, move or fake it. It fades soon after the last act, and at once when the person takes over.
- **Take over.** A click in the page, or ⌘., takes over the tab. A "You're driving" bar shows at the foot of the page, the agent's commands on that tab are refused, and the agent's face looks up at the person. ⌘↩ or Hand Back gives it back. The agent's next command on that tab is refused once, so it looks at the page again before going on.
- **Never forward.** Agent tabs never come forward by themselves, and their visits stay out of history.
- **Keep.** Keep Tabs, or `broadway tabs keep`, makes an agent's tab the person's.
- **Closing.** An agent's tabs close when its session ends, as above. Nothing else closes them, and no setting changes when.

## The face

Each agent has a face drawn in code: a rounded square head in the agent's colour, with two tall eyes. Claude Code is always coral and Codex periwinkle, and other names get a colour from their name.

| State | Face |
| --- | --- |
| idle | eyes open and still |
| reading | eyes scan along a line and blink now and then |
| typing | eyes look down |
| waving (needs the person) | large round eyes look up and the head sways |
| driving (the person took over) | eyes look up at the person |
| done | happy eyes and a tick |
| failed | small round eyes sit low and the head slumps |

A session's heading shows the strongest state over its tabs: waving, then driving, then typing, then reading, then idle. It shows done or failed only once the session has ended. The face moves only while it is reading, typing or waving and on screen. Under Reduce Motion or Low Power Mode it shows a still frame. Blinks come from the session's id rather than a random clock, so a frame depends only on the state, the time and the session, and can be tested.

## Code

- `Sources/BroadwayCLI/Ancestor.swift`: the ancestor walk and the names sent with each request.
- `Sources/Search/AgentLinks.swift`: sessions, their keys, ends and states. `AgentPlaces.swift`: the session's space, its rules and what folders learned. `AgentLinkCommands.swift`: how a request finds its session, and the `agents` verbs.
- `Sources/Search/AgentGate.swift`: the modes, the acts and the verdict for each.
- `Sources/Search/AgentRows.swift`: `read --rows`, which gathers every row of a list, table or grid. `AgentChecks.swift`: `audit`, `timings` and `styles`.
- `Sources/Search/AgentCommands.swift`: the error codes (`ToolCode`) and the reply envelope. `MCPServer.swift`: the MCP server, its tool names, instructions and short list. `AgentHandoff.swift`: `handoff`. `AgentAskOutside.swift`: `ask` for outside agents, its limits and its card words. `Sources/BroadwayCLI/MCPRelay.swift`: `broadway mcp` and its hand-over after an update.
- `Sources/Search/AgentsArea.swift`, `AgentCharacter.swift`, `AgentPointer.swift`, `AgentDriving.swift`: the area, the face, the pointer and take over. `SideCount.swift`: the count a folded folder and a folded agent share.
- Tests: `Tests/SearchTests/AgentLinksTests.swift`, `AgentPlacesTests.swift`, `AgentRowsTests.swift`, `AgentChecksTests.swift`, `AgentLeadTabTests.swift` for the area's headings and folds, and the hidden-world probes `Tests/agent_mode.py`, `Tests/agent_checks.py`, `Tests/agent_card.py` and `Tests/agent_spaces.py`. `Tests/agent_field.py` measures model agents on invented sites, the long list tasks (`ledger_sum`, `dispatch_count`, `stockroom_most`) among them.
