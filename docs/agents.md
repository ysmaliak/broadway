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
- **End.** A session ends on `broadway agents done` or `broadway agents disconnect`, when its MCP connection closes, when its ancestor process exits, or after 20 minutes with no request and no tab at work. `--summary TEXT` leaves a line for the person, up to 200 characters, and `--failed` marks it as not finished.
- **After the end.** The session's tabs are marked finished. Its heading keeps the tick or the downcast face, and the summary, until its tabs are closed. A session with no tabs leaves at once.
- **Again.** A request from the same agent after its session ended starts a new session.

Two sessions of the same program are numbered, such as "Claude Code 2". Each session keeps its own last tab, so two agents working at once don't take each other's tab.

### The session is who asks

When a command needs the person's yes, the session is what asks. The question shows on that session's tab, with the command quoted and the agent's name, and its face waves until the person answers. A yes for reading a site holds for the rest of the session. If Broadway is in the background, a notification says which agent needs the person.

A command waits 100 seconds for the answer, which is under Claude Code's default two-minute Bash timeout. `--wait-person MIN` waits longer and `--no-person` fails at once. When the wait runs out the command exits 3 with `needs_you`, nothing is done, and the question stays up. A yes that arrives after the agent stopped waiting is recorded, so the agent's next try goes through. It never acts by itself.

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
- `Sources/Search/AgentsArea.swift`, `AgentCharacter.swift`, `AgentPointer.swift`, `AgentDriving.swift`: the area, the face, the pointer and take over.
- Tests: `Tests/SearchTests/AgentLinksTests.swift`, and the hidden-world probe `Tests/agent_mode.py`.
