# Which tab comes next

Where a new tab goes, and which tab you land on when the one on screen closes or leaves. The rules follow Chrome and Firefox where the two agree, and are chosen for a vertical column with pins, folders, spaces and an Agents section where they don't.

The code is `Sources/Search/TabOrder.swift` (the way back and the next tab) and `open`, `newTab`, `close`, `leave` and the page-opened window path in `Browser.swift`. The unit tests are `Tests/SearchTests/TabOrderTests.swift`. The probe that drives the real app is `Tests/tab_order.py`.

## The way back

A tab can remember the tab to go back to when it closes. Chrome calls this the opener, Firefox the owner.

- A tab opened in front remembers the tab you were on: the New Tab button, ⌘T, the command bar, a duplicate, a link from another app, a bookmark opened in a new tab, a link or window a page opens in front.
- A link opened behind remembers the page it came from.
- A new tab that isn't a link forgets the way back as soon as you leave it, as Chrome does for ⌘T. A link keeps it while you move between the page and the tabs it opened.
- Going to any other tab forgets every way back, as Chrome does. Closing a tab or moving it away is not going somewhere, so it forgets nothing.
- A page's own navigation forgets nothing. Chrome forgets on a typed address in the page, Firefox doesn't. Broadway follows Firefox: the tab you came from is still the right place to go back to.
- An agent's tab is never a way back, and a hidden helper tab never is.

## When the tab on screen closes or leaves

The first of these that applies, for ⌘W, the cross, a page closing itself, Move to Space and Move to Window:

1. The other side of its Split View pair.
2. An agent's tab goes back to the last tab you looked at that isn't an agent's.
3. A link opened behind goes to the next link opened behind from the same page, below it first and then above, and after the last of them back to that page (Chrome's order).
4. Any other tab with a way back goes back to it.
5. Settings, History and the other pages of Broadway's own go back to the tab looked at before them.
6. A tab in a folder goes to the next tab in the same folder, below and then above.
7. The next tab on screen in the column, below and then above. Tabs folded away in a closed folder, agents' tabs and hidden helper tabs are skipped.

A pin, and a page in a folder that stays in the column, is put down rather than closed. Then the way back comes first and otherwise the last tab you looked at that isn't a pin. A tab you are not on closes without changing anything you see.

## The table

Sources, fetched on 2026-11-16 and kept as data only: Chromium `chrome/browser/ui/tabs/tab_strip_model.cc` and `chrome/browser/ui/browser_commands.cc` on main, Firefox `browser/components/tabbrowser/Tabbrowser.sys.mjs`, `browser/components/tabbrowser/content/tabs.mjs`, `browser/components/sessionstore/SessionStore.sys.mjs` and `browser/app/profile/firefox.js` on main, Apple's Safari User Guide for macOS 27 (Use tabs for webpages, Change Tabs settings, Close tabs) and Arc's release notes. Safari's only related settings are Open pages in tabs instead of windows and When a new tab or window opens, make it active. Arc's notes say only that the next tab after a close was improved. Apple and Arc describe little of this. Where they say nothing the cell says so.

### Where a new tab goes

| Case | Broadway before | Chrome | Firefox | Safari | Arc | Broadway now |
|---|---|---|---|---|---|---|
| New Tab button or ⌘T | Last loose tab, selected. An empty tab already there is moved down and used | End of the strip, selected, `DetermineInsertionIndex` | End, `insertAfterCurrent` false | Not documented | New Tab button at the bottom of the sidebar (release notes) | Same |
| Link opened behind (⌘-click, middle click, Open Link in New Tab) | After its page, after the links it opened before, in click order | After the last tab opened by the page, `GetIndexOfLastWebContentsOpenedBy` | After the last related tab, `insertRelatedAfterCurrent` true | Not documented | Not documented | Same |
| Link opened in front (⇧⌘-click) | After its page | Right after the page | After the last related tab | Not documented | Not documented | Same |
| Link with `target=_blank`, or a window a page opens | Last in the column | Right after the page (a link transition) | After the page | Opens as a tab with Open pages in tabs on Automatically | Not documented | After its page, in its folder, selected |
| Command bar into a new tab, a bookmark in a new tab, a link from another app | Next to the tab you are on | End of the strip | End of the strip | Not documented | Not documented | Same, left on purpose (see below) |
| New Tab in a folder | After the tab you are on in the folder, or at the folder's end | Not applicable | Not applicable | Not applicable | Not documented | Same |
| Duplicate | Next to the tab, selected | Next to the tab, keeps the opener, `DuplicateTabAt` | Next to the tab, the tab as owner, `SessionStore.duplicateTab` | Not documented | Not documented | Same |
| Reopened closed tab | Where it was, selected | Not checked | Not checked | History › Recently Closed, not where | Reopens with its history (release notes) | Same |
| Tab moved from another space or window | Next to the tab you are on there, selected | Not checked | Not checked | Dragged between windows, not where | Not documented | Same |

### Which tab you land on

| Case | Broadway before | Chrome | Firefox | Safari | Arc | Broadway now |
|---|---|---|---|---|---|---|
| New tab from the button, closed straight away | The tab that was last in the column | The tab you were on, `reset_opener_on_active_tab_change` | The tab you were on, owner set for a tab opened in front | Not documented | Not documented | The tab you were on |
| New tab, left and come back to, then closed | The tab that was last in the column | Neighbour | Neighbour (owner cleared on leaving) | Not documented | Not documented | Neighbour |
| Link opened in front, closed | Its neighbour | The page, opener | The page, `selectOwnerOnClose` true | Back closes the tab and returns to the page (Close tabs page) | Not documented | The page |
| Three links opened behind, closed one after another | Each neighbour, then the tab after them | The next link, then the page, `DetermineNewSelectedIndex` | The next link, then the neighbour | Not documented | Not documented | The next link, then the page |
| Link after you went to an unrelated tab, then closed | Neighbour | Neighbour, openers forgotten on a user switch | Neighbour, owner cleared | Not documented | Not documented | Neighbour |
| Last tab in the column | The one above | The one before | The one before | Not documented | Not documented | Same |
| First tab | The one below | The one after | The one after | Not documented | Not documented | Same |
| Tab in a folder | The next tab in the row, even out of the folder | Next in the same group, then before it | Next visible tab | Tab groups only, not documented | Not documented | Next in the same folder, then before it, then the column |
| Pin | Put down, last loose tab looked at | Pinned tabs close like others | Pinned tabs close like others | Not documented | Not documented | Same, with the way back first |
| Split View | The other side | The other side, after the opener rules | Not checked | Not documented | Not documented | Same |
| Only tab | A new empty tab, the window closes on an empty one | Not checked | The window closes, `closeWindowWithLastTab` true | Not documented | Not documented | Same, left on purpose |
| Several at once | The tab kept, else the next one left | One block, then the same order | Excludes the closing tabs | Not documented | Not documented | Same, through the same rules |
| Tab closed by its page, while on screen | The page that opened it | Same rules as a close | Same rules as a close | Not documented | Not documented | Same, left on purpose |
| Tab closed by its page, behind | Jumped to the page that opened it | Nothing changes | Nothing changes | Not documented | Not documented | Nothing changes |
| A tab you are not on | Nothing changes | Nothing changes | Nothing changes, `_findTabToBlurTo` | Not documented | Not documented | Same |
| Agent's tab you were looking at | Neighbour, unless that was an agent's tab | Not applicable | Not applicable | Not applicable | Not applicable | The last tab you looked at that isn't an agent's |
| Neighbour is an agent's tab | Mapped to the last tab looked at | Not applicable | Not applicable | Not applicable | Not applicable | Skipped |
| Moved to another space or window | Neighbour in the row, an agent's tab included | Same rules as a close | Same rules as a close | Not documented | Not documented | Same rules as a close |
| Put to sleep | A tab on screen never sleeps | Not applicable | Not applicable | Not applicable | Not documented | Same |
| Its folder closes | Each tab closes, the one on screen last, to its neighbour | Next tab outside the group, after the opener rules | Next visible tab | Not documented | Not documented | Same rules, so the next tab outside the folder |
| Live Folder row leaves | Same as a close | Not applicable | Not applicable | Not applicable | Not applicable | Same as a close |

### Moving between tabs

| Case | Broadway | Chrome | Firefox | Safari | Arc |
|---|---|---|---|---|---|
| Next and previous tab past the ends | Round to the other end | Round, `SelectRelativeTab` | Round, `advanceSelectedTab` with wrap | Not documented | Not documented |
| ⌃Tab | Most recently used | In order | In order, `browser.ctrlTab.sortByRecentlyUsed` false | Not documented | Most recently used, with ⌃W to close from it (release notes) |

## Left as it was on purpose

- New tabs that aren't links (the command bar, bookmarks, another app) open next to the tab you are on, not at the end as in Chrome and Firefox. Firefox offers the same as `insertAfterCurrent`, and in a long column the end is far from where you are. They remember the way back, so closing one straight away returns.
- Closing the only tab leaves an empty one, and closing that closes the window. Chrome, Firefox and Safari close the window at once. Broadway keeps the window and its pins.
- A tab closed by its own page while on screen goes back to the page that opened it even after other tabs were looked at, so a sign-in window always hands you back to the page it signed in.
- ⌃Tab keeps the most recently used order, as Arc has it.
- Pins and pages in folders that stay in the column are put down, not closed, as before.
