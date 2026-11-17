# Agents in Broadway

Outside agents (Claude Code, Codex, Cursor, a script) use Broadway through the `broadway` command or `broadway mcp`. Each one is an **agent session**. Broadway shows every session in an Agents area at the foot of the sidebar, with a face, a name, what it is doing and its tabs. The person can watch an agent work, take over a tab and hand it back. The agent runs outside Broadway, and Broadway shows it working.

Nothing works until the person turns on Settings › Agents › Let agents use Broadway. The command reference is [cli.md](cli.md).

## Sessions

### Telling one agent from another

Each `broadway` run is a new process, often in a new shell, so neither the connection nor an exported variable can hold a session. Instead the command sends its **agent ancestor** with every request:

- It walks up from its parent process, passing over shells and launchers (`zsh`, `bash`, `fish`, `env`, `sudo`, `timeout`, `xargs`, `tmux`, `npx` and the like), and stops at the first other process. It sends that process's id, its start time and its name. The start time means a reused process id can't join an old session.
- A `node`, `bun` or `deno` process running Claude Code's or Codex's script is named for the agent, not the interpreter.
- The name shown comes from the program: `claude` is Claude Code, `codex` is Codex, `cursor` is Cursor, and so on. Anything else is shown by its own name.
- `BROADWAY_AGENT_NAME` sets the name. `BROADWAY_AGENT` names a session outright, for a script that wants several sessions from one shell.
- `broadway mcp` holds its connection open, so the connection is the session. Its name comes from the client's name in MCP's `initialize`.

A person typing `broadway` at their own terminal gets a session named for the terminal app.

### Life of a session

- **Start.** `broadway agents connect [--name NAME]` starts the session at once. Otherwise the first command that opens or works in a tab starts it, and other commands only join a session that exists.
- **Between steps.** While nothing is at work in its tabs, a session's line reads "Thinking". It never says "Waiting", which read as waiting for the person.
- **Finished turn.** When the agent's turn ends, its card reads finished, with the tick face and the last thing it did, such as "Finished after reading example.com", or the agent's own `--summary`. The session stays live: its tabs stay as they are and its next command makes the same card work again. Broadway learns it from, in order of trust:
  - the agent's **Stop hook**, which runs `broadway agents idle --hook claude` (or `codex`) with the hook's event on stdin. `broadway setup claude` and `broadway setup codex` add it, and Broadway runs `broadway setup claude codex` itself when the person turns agents on, and once at the first launch that finds agents already on. When nothing is at `~/.local/bin/broadway`, that run is `broadway setup command claude codex`, so the hook has a command to call. The refresh at every launch never adds one, it only brings Broadway's own entries up to date. A Stop with background tasks or scheduled wakeups still pending is not a finished turn.
  - `broadway agents idle [--summary TEXT]`, for an agent or script that says so itself.
  - an MCP connection that shares a session with the agent's commands closing.
  - **Quiet time.** With no hook, after 2 minutes with no request, no call in flight, no question up, no download under way and no tab at work, the line reads "Idle", or "Idle after reading example.com", with the sleeping face.
  A question up for the person always wins: such a session reads "Needs you", never finished or idle.
- **End.** A session ends on `broadway agents done` or `broadway agents disconnect`, on the agent's **SessionEnd hook**, when its own MCP connection closes, when its ancestor process exits (for a session keyed by the agent's session id, when the `claude`, `codex`, `cursor` or `windsurf` process its commands came from exits), or after 20 minutes with no request and no tab at work. `--summary TEXT` leaves a line for the person, up to 200 characters, and `--failed` marks it as not finished. `agents done` wins over a finished turn.
- **The folded header** counts sessions as waiting for you, working (which includes Thinking), done (which includes a finished turn), failed and idle. A finished agent never counts as working or as needing the person.
- **After the end.** The session's tabs stay open, as in 0.3, and `agents done` lists them in its answer. `agents done --close` closes the ones the person never looked at. A `--tab` given to `agents done` is ignored. The tabs are marked finished. Its heading keeps the tick or the downcast face, and the summary, until its tabs are closed. A session with no tabs leaves at once.
- **Again.** A request from the same agent after its session ended starts a new session.

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

Signing in and filling forms with saved details stay with Broadway's own tasks. An outside agent uses `broadway fill`, which asks the person every time.

## What the person decides

All of these are in Settings › Agents, and none of them can be changed from the command line:

- **Let agents use Broadway.** Off until the person turns it on.
- **Agents ask first: Ask, Auto or Bypass.**
  - Ask asks before tabs, the Mac, signing in, sending, paying, deleting and uploading.
  - Auto asks before the Mac, sending, paying, deleting and uploading.
  - Bypass never asks, except before using the Mac. Captchas and passkeys still stop for the person.
- **Sites.** A site can be marked Always Here or Never Here from a question's answer. Never Here refuses every act on it. Always Here lets everything through except paying.
- **Connected agents**, and **the broadway command** for setting it up.

[cli.md](cli.md#who-may-do-what) lists how each command is gated.

## The Agents area

The area is one row at the foot of the sidebar, below the tabs. It is shaped like a tab row: up to three faces where a row's icon would be, the title "Agents", and a line under it saying what is going on, such as "2 working" or "Claude Code · Typing on github.com".

- **Folded by default.** A press unfolds it, and the choice holds for the whole app.
- **Unfolded**, it lists each session's tabs as rows, indented as in a folder, with a live dot while the agent is acting in a tab. With several sessions each gets a heading with its face, name and status line. With one session its tabs sit straight under the row.
- **Needs you.** When a question waits, the row says "Claude Code needs you" with the question, and a press goes to the tab that asks.
- **Height.** The area takes at most 40 percent of the sidebar. Past that it scrolls, with the session that needs the person kept in view. The tab list ends above it.
- **Which window.** A window shows the sessions that have tabs in it, in any of its spaces. A session with no tab yet shows in the front window.
- **Menu.** A session's menu has Keep Tabs, Close Tabs, and Disconnect while it is connected. Disconnecting ends the session from Broadway's side, and the agent's next command starts a new one. Broadway's own tasks show here too, with Stop Task instead.

A session's tabs live only in the area, not in the tab list. A tab of the person's that an agent works in stays where it is, with a small face on its row.

## Watching an agent

- **Opening a tab.** Pressing a row shows the tab, switching space if needed. Showing a tab doesn't stop the agent.
- **The pointer.** When the agent clicks, types, presses, scrolls or hovers, Broadway draws its pointer over the page, in the agent's colour with its name: it moves to each target, rings on a click and outlines a field while typing. It is drawn by Broadway above the page, so the page can't see, move or fake it. It fades soon after the last act, and at once when the person takes over.
- **Take over.** A click in the page, or ⌘., takes over the tab. A "You're driving" bar shows at the foot of the page, the agent's commands on that tab are refused, and the agent's face looks up at the person. ⌘↩ or Hand Back gives it back. The agent's next command on that tab is refused once, so it looks at the page again before going on.
- **Never forward.** Agent tabs never come forward by themselves, and their visits stay out of history.
- **Keep.** Keep Tabs, or `broadway tabs keep`, makes an agent's tab the person's.
- **Closing.** A finished agent tab the person has opened closes an hour after it finished or was last looked at. A tab nobody opened stays until it is closed.

## The face

Each agent has a face drawn in code: a rounded square head in the agent's colour, with two tall eyes. Claude Code is always coral and Codex periwinkle, and other names get a colour from their name.

| State | Face |
| --- | --- |
| idle | eyes open and still |
| reading | eyes scan along a line and blink now and then |
| typing | eyes look down |
| waving (needs the person) | eyes look up and a hand waves |
| driving (the person took over) | eyes look up at the person |
| done | happy eyes and a tick |
| failed | eyes look down |

A session's heading shows the strongest state over its tabs: waving, then driving, then typing, then reading, then idle. It shows done or failed only once the session has ended. The face moves only while it is reading, typing or waving and on screen. Under Reduce Motion or Low Power Mode it shows a still frame. Blinks come from the session's id rather than a random clock, so a frame depends only on the state, the time and the session, and can be tested.

## Code

- `Sources/BroadwayCLI/Ancestor.swift`: the ancestor walk and the names sent with each request.
- `Sources/Search/AgentLinks.swift`: sessions, their keys, ends and states. `AgentLinkCommands.swift`: how a request finds its session, and the `agents` verbs.
- `Sources/Search/AgentGate.swift`: the modes, the acts and the verdict for each.
- `Sources/Search/AgentCommands.swift`: the error codes (`ToolCode`) and the reply envelope. `MCPServer.swift`: the MCP server, its tool names, instructions and short list. `AgentHandoff.swift`: `handoff`. `Sources/BroadwayCLI/MCPRelay.swift`: `broadway mcp` and its hand-over after an update.
- `Sources/Search/AgentsArea.swift`, `AgentCharacter.swift`, `AgentPointer.swift`, `AgentDriving.swift`: the area, the face, the pointer and take over.
- Tests: `Tests/SearchTests/AgentLinksTests.swift`, and the hidden-world probe `Tests/agent_mode.py`.
