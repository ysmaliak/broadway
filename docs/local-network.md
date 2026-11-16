# Local network protection

Broadway asks before a public website reaches this Mac or the local network: a dev server on `localhost`, a router's admin page, a NAS. Public pages that scan `localhost` ports, fingerprint the servers you run or poke at a router are known attacks. Chrome and other browsers ask the same question.

It is built so it never gets in the way of your own local pages. It is always on, and has no switch in Settings.

The code is `Sources/Search/LocalNetwork.swift` (the classifier, the rule list and `LocalNetworkGuard`) and the navigation and rule-list callbacks in `Browser.swift`.

## What is asked about, and what never is

Asked: a page whose **top-level origin is public** reaching a **local address** by any of these routes:

- a subresource (image, script, stylesheet, font, media),
- `fetch`, `XMLHttpRequest`, `sendBeacon` or `EventSource`,
- a WebSocket,
- an iframe,
- a top-level navigation the page's script started (`location = …`, `a.click()` from a timer, a form submitted by script).

Never asked:

- A local page reaching a local address. A dev page at `localhost:3000` calling `localhost:8080`, `myapp.test` calling `api.localhost`, or a router's page calling the router are left alone. The guard isn't even attached to a local page.
- A top-level navigation the person started: typed in the field, opened from the command bar or a bookmark, a link clicked, a submit button pressed. WebKit marks clicks and presses as user initiated (`_isUserInitiated`). Broadway's own loads are recognised another way: the tab's web view keeps the `WKNavigation` its last load returned, and a navigation whose `_mainFrameNavigation` is that one is Broadway's.
- A server redirect at the top level (`302 Location: http://localhost:8085/callback`). This is how command-line sign-ins such as `gh auth login` and OAuth loopback callbacks come back.
- Back, forward and reload.
- A site with Developer Mode on, which can be turned on for any site from the tab menu.

### What counts as local

One classifier, `LocalNetwork.reach`, answers `loopback`, `lan` or `internet`. Everything else derives from it: whether a page is public, whether a navigation's target is local, and the content rule list's URL filters. A unit test runs one table of hosts through both the classifier and the compiled filters and checks they agree.

| Kind | Hosts |
| --- | --- |
| loopback | `localhost`, `*.localhost`, `127.0.0.0/8`, `0.0.0.0/8` (which reaches this Mac on macOS), `[::1]`, `[::]`, and the IPv4-mapped forms of these |
| lan | `10/8`, `172.16/12`, `192.168/16`, `169.254/16` (link-local), `100.64/10` (shared address space, which Tailscale uses for a tailnet), `[fc00::/7]`, `[fe80::/10]`, the IPv4-mapped forms of these, `*.local` (Bonjour), `*.test`, `*.internal`, `*.home.arpa`, and single-label names such as `http://nas:5000/` |

`*.test` is local because Developer Mode treats it as local (`LocalServer.isLocal`), and tools such as Laravel Valet point it at this Mac. A test checks that everything Developer Mode calls local, this classifier does too, so the two never disagree about what a dev page is.

`100.64/10` is included although Chrome leaves it out. On a Mac it is most likely a tailnet of the person's own machines. A page served from a tailnet machine is then local and never asked about, and a public site reaching a tailnet machine is asked about.

WebKit hands the content rule list and the navigation delegate canonical URLs. `http://2130706433/`, `http://0x7f.1/` and `http://127.1/` all arrive as `http://127.0.0.1/`, so dotted-quad matching is enough.

## How it works in WKWebView

Four mechanisms were weighed:

| Mechanism | Catches | Misses |
| --- | --- | --- |
| A content rule list | every load WebKit makes for the page: subresources, fetch and XHR, beacons, EventSource, WebSockets, iframes. It is enforced inside WebKit before the request leaves, and the page can't get around it | top-level navigations, because a rule can't tell typed from script. Anything decided by DNS |
| A script shim wrapping `fetch`, `XMLHttpRequest` and `WebSocket` | calls from the page's script | it must run in the page's world, so the page can grab the originals first. It misses `<img>`, `<script>`, `<iframe>`, CSS, workers and beacons |
| The navigation delegate | top-level and frame navigations, with who started them | every subresource, fetch and WebSocket |
| A network extension or proxy | everything, including DNS answers | it needs a system extension, an entitlement and an install prompt |

Broadway uses **a content rule list for everything below the top level, and the navigation delegate for the top level.** A script shim would add a layer a page can get around over a list that already catches the same calls.

### The rule list

`broadway-local-network` is compiled once at launch into the content blocker's store. Each URL filter is its own rule, because WebKit's filters have no `|`:

```json
{"trigger": {"url-filter": "^[a-z]+://([^/@]*@)?127\\.[0-9]+\\.[0-9]+\\.[0-9]+\\.?(:[0-9]+)?/", "load-type": ["third-party"]},
 "action": {"type": "block"}}
```

`load-type: third-party` keeps the main document out of it. A request from a public page to a local host is always third party, so nothing real is lost.

Per-site answers are not compiled into the list. At each main-frame navigation the list is added to the tab's own `WKUserContentController` or taken off it, the same way the ad blocker is turned off for one site. Every tab has its own controller, and a popup gets a new one, so a site allowed in one tab never opens up another. The list is attached only when:

- the page the tab is going to is `http` or `https` and public,
- the site hasn't been allowed (in this tab, for a private one),
- Developer Mode is off for it.

### Knowing a request was stopped

WebKit tells the navigation delegate whenever a content rule list acted, through `_webView:contentRuleListWithIdentifier:performedAction:forURL:`. The action's `blockedLoad` says it blocked. Broadway reads it by key, as it reads `_isContentExtensionRedirect`, so no private class is linked. It fires for fetch, XHR, images and iframes.

**WebSockets are blocked but not reported.** The list stops a WebSocket to `localhost` before it connects, but WebKit never calls the delegate for it. A page whose only local traffic is a WebSocket fails without a question. The way out for such a site is Developer Mode on it. Reporting it would take a message handler in the page's own world, which every public page could see, and Broadway keeps its handlers in its own world.

The list blocks first and tells second, so **the first request fails**. If the person allows, the list comes off and the page reloads. That is the cost of enforcement inside WebKit: a subresource can't be held while a question is up. A page that only probes the network in the background gets nothing until someone says yes.

### Top-level navigation from script

A main-frame navigation is held and asked about when all of these hold:

- the page it comes from is public,
- the target is local,
- it isn't user initiated or one of Broadway's own loads,
- it isn't a server redirect, back, forward or reload.

Allow lets the same navigation go on, with nothing to reload. Don't Allow cancels it.

## The question

The same card that camera, location and notifications use, over the page that asked:

> **example.com wants to reach apps on this Mac, at localhost:3000** · Allow · Don't Allow
>
> **example.com wants to reach devices on your network, at 192.168.1.20** · Allow · Don't Allow

- The answer is kept per site, by the top-level origin, with the other site permissions. Site Controls shows it as Local network, Settings › Websites › Site permissions lists each answered site with a Remove button, and `broadway permissions list` and `broadway permissions reset` read and forget it.
- A private tab's answer lasts as long as the tab and is never written down.
- A page is asked at most once. A page firing twenty blocked requests gets one card. If another permission card is already up, the page isn't asked this time and the request stays blocked.
- Don't Allow is kept, so the site isn't asked again until the answer is forgotten.
- A card that goes away unanswered, because its window closed, is not an answer. Nothing is kept, and the site is asked again next time.

## Gaps

- **DNS.** The filter sees names, not addresses. `router.example.com` resolving to `192.168.1.1`, DNS rebinding, and `*.nip.io` names are not caught. That needs the resolved address, which WebKit gives neither a rule list nor a delegate. Only a network extension could.
- **Names Broadway doesn't know.** `.lan`, `.home`, `.corp` and other private suffixes a router hands out are not on the list. Single-label names are.
- **The first request fails.** Allow reloads the page.
- **WebSockets are not reported.** They are blocked, but no question is asked.
- **Top-level server redirects** to local addresses go through on purpose, for sign-in callbacks.
- **Pages without an http or https origin.** `about:blank` and `data:` windows a public page writes into, and `blob:` documents, have no public host of their own, so the list isn't attached and their requests go through.
- **Workers.** Service worker and shared worker requests follow whatever WebKit does for content rule lists there. This is not verified.
- **WebRTC** connections to local addresses aren't covered. WebKit already hides local ICE candidates behind mDNS names.
- **`0.0.0.0`** is refused by WebKit itself before the list sees it. The filter stays as a backstop.
- **Mixed content** already stops most of the network case from `https` pages: WebKit blocks an `http://192.168.x.x` fetch from an `https` page. It doesn't stop `http://localhost` or `http://127.0.0.1`, which count as potentially trustworthy. That is the case this mostly protects.
- **Other web views.** Extension pages, the side panel and offscreen documents keep their own delegates and aren't guarded.

## Tests

- `Tests/SearchTests/LocalNetworkTests.swift`: the classifier over a table of hosts, the filters against the same table (through `NSRegularExpression`, and compiled by WebKit's own store), that everything `LocalServer.isLocal` calls local is local here too, the attach decision and the navigation decision.
- `Tests/local_network.py`, a probe in a hidden test world. A test-only variable, `SEARCH_PUBLIC_HOSTS`, read only on a test run, makes `127.0.0.1` count as public, and the page on it reaches a second server at `localhost`. It checks blocked, asked, Don't Allow kept, forgotten, then Allow, reload and reached. It checks fetch, XHR, image, iframe and WebSocket are blocked, a script navigation is held, asked and let through, a load Broadway starts and a server redirect are never asked about, a private tab's answer is kept only by the tab, a local page reaching another local server is never asked about, a Developer Mode site is never asked about, and nothing happens with the guard off.
