import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentRowsTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer?

    static let table = "<!doctype html><html lang=\"en\"><title>Ledger</title><h1>Ledger</h1><table><thead><tr><th>Entry</th><th>Amount</th></tr></thead><tbody>"
        + (1...60).map { "<tr><td>LG-\(1000 + $0)</td><td>\($0 * 3).50</td></tr>" }.joined() + "</tbody></table>"

    static let drawn = """
    <!doctype html><html lang="en"><title>Log</title><h1>Log</h1>
    <div id="log" role="list" style="height:300px;overflow-y:auto;position:relative"><div id="room" style="position:relative"></div></div>
    <script>
    var tall = 30, box = document.getElementById('log'), room = document.getElementById('room'), count = 400;
    room.style.height = (count * tall) + 'px';
    function draw() {
      var first = Math.max(0, Math.floor(box.scrollTop / tall) - 2), last = Math.min(count, Math.ceil((box.scrollTop + box.clientHeight) / tall) + 2);
      room.textContent = '';
      for (var i = first; i < last; i++) {
        var row = document.createElement('div');
        row.setAttribute('role', 'listitem');
        row.style.cssText = 'position:absolute;left:0;right:0;height:30px;top:' + (i * tall) + 'px';
        row.innerHTML = '<span></span> <span></span>';
        row.children[0].textContent = 'P-' + (i + 1); row.children[1].textContent = (i % 7 === 0 ? 'Upwell' : 'Garrow');
        room.appendChild(row);
      }
    }
    box.addEventListener('scroll', draw);
    draw();
    </script>
    """

    static let cards = """
    <!doctype html><html lang="en"><title>Shelves</title><h1>Shelves</h1>
    <div id="cards" style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px"></div><p id="more">Loading</p>
    <script>
    var made = 0, busy = false, cards = document.getElementById('cards');
    function next() {
      if (busy || made >= 90) return;
      busy = true;
      setTimeout(function () {
        for (var i = 0; i < 18 && made < 90; i++, made++) {
          var a = document.createElement('article');
          a.style.cssText = 'height:140px;background:#eee';
          a.innerHTML = '<h3></h3><p></p>';
          a.children[0].textContent = 'Item ' + (made + 1); a.children[1].textContent = ((made * 37) % 500) + ' units';
          cards.appendChild(a);
        }
        busy = false;
        if (made >= 90) document.getElementById('more').textContent = 'All shown';
        check();
      }, 250);
    }
    function check() { if (scrollY + innerHeight > document.documentElement.scrollHeight - 200) next(); }
    addEventListener('scroll', check);
    next();
    </script>
    """

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
    }

    private func tearDown() async {
        server?.stop()
        AgentSites.shared.reset()
        AgentDesk.shared.drop(task: task)
        browser?.closeAll()
        browser = nil
    }

    private func open(_ html: String) async throws -> (tab: Tab, id: String) {
        server?.stop()
        server = try LocalPageServer(["/page": .init(type: "text/html", body: html)])
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": server!.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { !before.contains($0.id) })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func rows(_ said: ToolOutcome) -> [[String]] {
        (said.data?["rows"] as? [[Any]] ?? []).map { $0.map { "\($0)" } }
    }

    @Test func aTableGivesItsHeaderFirstAndEveryRow() async throws {
        let (_, id) = try await open(Self.table)
        let said = await box.call("text", ["tab": id, "rows": true], task: task)
        #expect(!said.failed, "\(said.text ?? "")")
        #expect(said.data?["header"] as? [String] == ["Entry", "Amount"])
        #expect(rows(said).count == 60)
        #expect(rows(said).last == ["LG-1060", "180.50"])
        #expect(said.data?["end"] as? Bool == true)
        #expect(said.text?.contains("Entry | Amount\nLG-1001 | 3.50") == true)
        #expect(said.text?.contains("It reached the end") == true)
    }

    @Test func aListThatDrawsOnlyNearRowsIsGatheredWholeAndItsScrollPutBack() async throws {
        let (tab, id) = try await open(Self.drawn)
        _ = await PageSelection.run(tab, "document.getElementById('log').scrollTop = 600; return true;")
        let said = await box.call("text", ["tab": id, "rows": true, "max": 1000], task: task)
        #expect(!said.failed, "\(said.text ?? "")")
        let found = rows(said)
        #expect(found.count == 400)
        #expect(Set(found.map { $0.first ?? "" }).count == 400)
        #expect(found.filter { $0.last == "Upwell" }.count == 58)
        #expect(said.data?["end"] as? Bool == true)
        let back = await PageSelection.run(tab, "return document.getElementById('log').scrollTop;") as? Double
        #expect(back == 600)
    }

    @Test func aGridThatLoadsMoreAsItScrollsIsReadToTheEnd() async throws {
        let (_, id) = try await open(Self.cards)
        let said = await box.call("text", ["tab": id, "rows": true], task: task)
        #expect(!said.failed, "\(said.text ?? "")")
        #expect(rows(said).count == 90)
        #expect(rows(said).first == ["Item 1", "0 units"])
        #expect(said.data?["kind"] as? String == "grid")
        #expect(said.data?["end"] as? Bool == true)
    }

    static let slow = """
    <!doctype html><html lang="en"><title>Slow shelves</title><h1>Slow shelves</h1>
    <div id="cards" style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px"></div><p id="more">Loading</p>
    <script>
    var made = 0, busy = false, cards = document.getElementById('cards');
    function next() {
      if (busy || made >= 72) return;
      busy = true;
      fetch('/more').then(function (r) { return r.text(); }).then(function () {
        for (var i = 0; i < 24; i++, made++) {
          var a = document.createElement('article');
          a.style.cssText = 'height:160px;background:#eee';
          a.textContent = 'Shelf item ' + (made + 1);
          cards.appendChild(a);
        }
        busy = false;
        check();
      });
    }
    function check() { if (scrollY + innerHeight > document.documentElement.scrollHeight - 200) next(); }
    addEventListener('scroll', check);
    next();
    </script>
    """

    @Test func aGridWhoseNextPageComesSlowlyIsReadToTheEndAndNotCalledWholeTooSoon() async throws {
        server?.stop()
        server = try LocalPageServer(["/page": .init(type: "text/html", body: Self.slow), "/more": .init(type: "text/plain", body: "ok", hold: 1.8)])
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": server!.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { !before.contains($0.id) })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id, "text": "Shelf item 24"], task: task)
        let said = await box.call("text", ["tab": id, "rows": true], task: task)
        let count = rows(said).count
        #expect(count == 72 || said.data?["end"] as? Bool == false, "\(count) rows, \(said.text?.prefix(200) ?? "")")
        #expect(count == 72, "\(said.text?.prefix(300) ?? "")")
    }

    @Test func maxStopsEarlyAndSaysItIsNotTheWholeList() async throws {
        let (_, id) = try await open(Self.drawn)
        let said = await box.call("text", ["tab": id, "rows": true, "max": 25], task: task)
        #expect(rows(said).count == 25)
        #expect(said.data?["end"] as? Bool == false)
        #expect(said.data?["stopped"] as? String == "max")
        #expect(said.text?.contains("Not the whole list. It stopped at 25 rows.") == true)
    }

    @Test func twoRowsThatReadTheSameAtDifferentPlacesAreBothKept() async throws {
        let html = "<!doctype html><html lang=\"en\"><title>Twins</title><h1>Twins</h1><table>"
            + (0..<8).map { _ in "<tr><td>Same</td><td>1</td></tr>" }.joined() + "</table>"
        let (_, id) = try await open(html)
        let said = await box.call("text", ["tab": id, "rows": true], task: task)
        #expect(rows(said).count == 8)
        #expect(said.data?["alike"] as? Int == 7)
    }

    @Test func inReadsTheListThatHoldsThatElement() async throws {
        let html = "<!doctype html><html lang=\"en\"><title>Two</title><h1>Two</h1><ul><li><a href=\"#a\">Alpha</a></li><li><a href=\"#b\">Beta</a></li></ul>"
            + "<ul>" + (1...9).map { "<li>Row \($0)</li>" }.joined() + "</ul>"
        let (_, id) = try await open(html)
        let whole = await box.call("text", ["tab": id, "rows": true], task: task)
        #expect(rows(whole).count == 9)
        let said = await box.call("text", ["tab": id, "rows": true, "in": "Alpha"], task: task)
        #expect(rows(said) == [["Alpha"], ["Beta"]], "\(said.text ?? "")")
    }

    @Test func aRowNeverShowsWhatIsInAPasswordBox() async throws {
        let html = "<!doctype html><html lang=\"en\"><title>Keys</title><h1>Keys</h1><table>"
            + (1...5).map { "<tr><td>Key \($0)</td><td><input type=\"password\" value=\"plum-otter-\($0)\"></td></tr>" }.joined() + "</table>"
        let (_, id) = try await open(html)
        let said = await box.call("text", ["tab": id, "rows": true], task: task)
        #expect(rows(said).count == 5)
        #expect(said.text?.contains("plum-otter") == false)
    }

    @Test func aRowLeavesOutWordsThatReadLeavesOut() async throws {
        let html = "<!doctype html><html lang=\"en\"><title>Hidden</title><h1>Hidden</h1><table style=\"background:#ffffff\">"
            + (1...5).map { "<tr><td>Row \($0)</td><td>Shown<span style=\"color:#ffffff;font-size:1px\"> white-words-\($0)</span><span style=\"opacity:0\"> clear-words-\($0)</span></td></tr>" }.joined() + "</table>"
        let (_, id) = try await open(html)
        let said = await box.call("text", ["tab": id, "rows": true], task: task)
        #expect(rows(said).first == ["Row 1", "Shown"], "\(rows(said))")
        #expect(said.text?.contains("white-words") == false)
        #expect(said.text?.contains("clear-words") == false)
    }

    @Test func rowsAreRefusedInATabThatIsNotTheAgents() async throws {
        server = try LocalPageServer(["/page": .init(type: "text/html", body: Self.table)])
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.showRow([mine], active: mine.id)
        mine.go(to: server!.url("/page"))
        let id = String(mine.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        let said = await box.call("text", ["tab": id, "rows": true], task: task)
        #expect(said.failed)
        #expect(said.text?.contains("works only in a tab of your own") == true)
    }

    @Test func maxOutsideItsRangeIsAMistake() async throws {
        let (_, id) = try await open(Self.table)
        for wrong in [0, 1001] {
            let said = await box.call("text", ["tab": id, "rows": true, "max": wrong], task: task)
            #expect(said.code == "usage")
        }
        let alone = await box.call("text", ["tab": id, "max": 10], task: task)
        #expect(alone.code == "usage")
    }

    @Test func aListThatComesAfterTheFirstAnswerIsWaitedForAndNotCalledMissing() async throws {
        server?.stop()
        let page = """
        <!doctype html><html lang="en"><title>Late</title><h1>Late</h1><ul id="late"></ul>
        <script>
        setTimeout(function () {
          fetch('/late').then(function (r) { return r.text(); }).then(function () {
            var ul = document.getElementById('late');
            for (var i = 1; i <= 30; i++) { var li = document.createElement('li'); li.textContent = 'Late item ' + i; ul.appendChild(li); }
          });
        }, 300);
        </script>
        """
        server = try LocalPageServer(["/page": .init(type: "text/html", body: page), "/late": .init(type: "text/plain", body: "ok", hold: 0.8)])
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": server!.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { !before.contains($0.id) })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()

        let said = await box.call("text", ["tab": id, "rows": true], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(rows(said).count == 30, "\(said.text?.prefix(200) ?? "")")
    }

    @Test func aCutAnswerSaysItIsNotWhole() {
        let found: [String: Any] = ["kind": "list", "ref": "e4", "rows": (1...50).map { ["Row \($0) " + String(repeating: "x", count: 40)] }, "end": true, "scrolled": true]
        let said = AgentRows.answer(found, max: 200, limit: 600)
        #expect(said.data?["end"] as? Bool == false)
        #expect((said.data?["cut"] as? Int ?? 0) > 0)
        #expect(said.text?.contains("Not the whole list.") == true)
        #expect(said.text?.contains("[…]") == true)
        #expect(said.text?.contains("It reached the end") == false)
    }

    @Test func theCommandGetsTheRowsAsTextAndNotOnlyAsData() {
        let found: [String: Any] = ["kind": "list", "ref": "e4", "rows": [["Row 1"], ["Row 2"]], "end": true, "scrolled": false]
        let data = ToolReply.data(AgentRows.answer(found, max: 200))
        #expect((data["text"] as? String)?.contains("Row 2") == true)
        #expect((data["text"] as? String)?.hasPrefix(ToolReply.notice) == false)
    }
}
