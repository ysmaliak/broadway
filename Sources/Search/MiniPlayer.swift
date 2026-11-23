import AppKit
import Combine
import Observation
import WebKit

struct MiniHeard {
    var report: MiniReport
    var frame: WKFrameInfo
    var main: Bool
    var at: Date
    var since: Double = 0
}

struct MiniSound: Equatable {
    var role = MiniRole.none
    var report = MiniReport()
    var playing = false
    var started: Double = 0
    var at = Date.distantPast
    var frame: String?
    var waited = false
    var held = false
}

extension Tab {
    static let soundFramesMost = 12

    func heardSound(_ body: [String: Any], in frame: WKFrameInfo) {
        guard let id = body["id"] as? String, !id.isEmpty, id.count < 40 else { return }
        if body["gone"] as? Bool == true {
            soundFrames[id] = nil
        } else {
            if soundFrames[id] == nil, soundFrames.count >= Self.soundFramesMost,
               let oldest = soundFrames.filter({ !$0.value.main }).min(by: { $0.value.at < $1.value.at })?.key {
                soundFrames[oldest] = nil
            }
            let report = MiniReport.parse(body)
            let was = soundFrames[id]
            let starts = report.reading?.playing == true && was?.report.reading?.playing != true
            soundFrames[id] = MiniHeard(report: report, frame: frame, main: frame.isMainFrame, at: Date(),
                                        since: starts ? Date().timeIntervalSinceReferenceDate : was?.since ?? 0)
        }
        soundChanged(noisy: false)
    }

    func soundChanged(noisy turned: Bool) {
        var next = sound
        if turned {
            soundWait?.invalidate()
            soundWait = nil
            next.waited = false
            if noisy {
                soundWait = Timer.scheduledTimer(withTimeInterval: MiniRule.lasting, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.soundWait = nil
                        guard self.noisy else { return }
                        self.sound.waited = true
                        self.soundChanged(noisy: false)
                    }
                }
            }
        }
        let heard = Array(soundFrames.values)
        if turned, noisy { next.held = false }
        let facts = MiniFacts(noisy: noisy, waited: next.waited, held: next.held, reports: heard.map(\.report))
        next.role = MiniRule.role(facts, was: sound.role)
        let lead = Self.leadFrame(soundFrames, was: sound.frame)
        next.frame = lead?.key
        next.report = lead?.value.report ?? MiniReport()
        next.at = lead?.value.at ?? Date()
        let report = next.report
        let playing = report.reading?.playing ?? noisy
        next.playing = playing || (noisy && report.reading == nil)
        if next.playing, !sound.playing { next.started = Date().timeIntervalSinceReferenceDate }
        if next.report.refused > 0, sound.report.refused != next.report.refused { forgetRefused(next.report.refused) }
        if next != sound { sound = next }
        if next.role == .float { Browsers.all.first { $0.floatMiss?.tab == id }?.pictureCame(self) }
    }

    static func leadFrame(_ frames: [String: MiniHeard], was: String?) -> (key: String, value: MiniHeard)? {
        let seen = frames.map { key, heard in
            MiniFrameSeen(key: key, main: heard.main, reading: heard.report.reading, declared: heard.report.session.declared,
                          since: heard.since, at: heard.at.timeIntervalSinceReferenceDate)
        }
        guard let key = MiniRule.lead(seen, was: was), let heard = frames[key] else { return nil }
        return (key, heard)
    }

    private func forgetRefused(_ rate: Double) {
        guard !shy, let site = VideoSpeed.site(of: pageAddress), let kept = VideoSpeed.kept(for: site), abs(kept - rate) < 0.01 else { return }
        VideoSpeed.forget(site)
        VideoSpeedBook.shared.changed()
    }

    var soundFrame: WKFrameInfo? {
        guard let key = sound.frame, let heard = soundFrames[key], !heard.main else { return nil }
        return heard.frame
    }

    func holdSound(_ on: Bool) {
        guard sound.held != on else { return }
        if !on { built?.setAllMediaPlaybackSuspended(false, completionHandler: nil) }
        sound.held = on
        soundChanged(noisy: false)
    }

    func forgetSound() {
        soundWait?.invalidate()
        soundWait = nil
        soundFrames = [:]
        if sound != MiniSound() { sound = MiniSound() }
    }
}

@MainActor
@Observable
final class MiniPlayer {
    struct Item: Identifiable, Equatable {
        let id: Tab.ID
        var title: String
        var detail: String
        var site: String
        var art: NSImage?
        var playing: Bool
        var pair: MiniPair
        var previous: Bool
        var next: Bool
        var position: MiniPosition?
        var live: Bool
        var rate: Double
        var speed: Bool
        var seekable: Bool
        var muted: Bool
        var skip: Int
        var waiting = false
        var icon: NSImage?

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.title == b.title && a.detail == b.detail && a.site == b.site && a.art === b.art
                && a.playing == b.playing && a.pair == b.pair && a.previous == b.previous && a.next == b.next
                && a.position == b.position && a.live == b.live && a.rate == b.rate && a.speed == b.speed
                && a.seekable == b.seekable && a.muted == b.muted && a.skip == b.skip && a.waiting == b.waiting
                && a.icon === b.icon
        }
    }

    struct Shown: Equatable {
        var item: Item?
        var items: [Item] = []
    }

    private(set) var item: Item?
    private(set) var items: [Item] = []
    private var artTurn = 0

    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private var dismissed: [Tab.ID: Double] = [:]
    @ObservationIgnored private var picked: (id: Tab.ID, at: Double)?
    @ObservationIgnored private var artwork: [String: NSImage] = [:]
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var follow: AnyCancellable?
    @ObservationIgnored private var front: AnyCancellable?
    @ObservationIgnored private var surface = false
    @ObservationIgnored private var holds: [Tab.ID: MiniHold] = [:]
    @ObservationIgnored private var asked: [Tab.ID: (rate: Double, at: Date)] = [:]
    @ObservationIgnored private var seen: Set<Tab.ID> = []
    @ObservationIgnored var staged: Item? { didSet { bump() } }
    private static let session = URLSession(configuration: .ephemeral)

    init(_ browser: Browser) {
        self.browser = browser
        follow = kitObserve(distinct: true, { [weak self] in self?.reckon() ?? Shown() }) { [weak self] shown in
            self?.publish(shown)
        }
        front = kitObserve(distinct: true, { [weak browser] in browser?.visibleTabIDs ?? [] }) { [weak self, weak browser] now in
            let came = Set(now).subtracting(self?.seen ?? [])
            self?.seen = Set(now)
            for tab in browser?.tabs ?? [] where came.contains(tab.id) && tab.sound.held { tab.holdSound(false) }
        }
    }

    init(surface item: Item) {
        surface = true
        self.item = item
        items = [item]
    }

    private func publish(_ shown: Shown) {
        if items != shown.items { items = shown.items }
        if item != shown.item { item = shown.item }
    }

    private func reckon() -> Shown {
        guard let browser else { return Shown() }
        let prefs = browser.prefs
        _ = artTurn
        if let staged { return Shown(item: staged, items: [staged]) }
        guard prefs.miniPlayer else { return Shown() }
        let tabs = (browser.tabs + browser.parkedTabs).filter { tab in
            tab.isWeb && !tab.asleep && !tab.floating && tab.sound.role == .mini && dismissed[tab.id] != tab.sound.started
                && !browser.onCall(tab)
        }
        let now = Date()
        let entries = tabs.map { (id: $0.id, playing: $0.sound.playing || holds[$0.id]?.sounding(now: now) == true, started: $0.sound.started) }
        let kept = Set(MiniRule.kept(entries))
        let staying = entries.filter { kept.contains($0.id) }
        var chosen = MiniRule.chosen(staying)
        if let picked, kept.contains(picked.id), !staying.contains(where: { $0.started > picked.at }) { chosen = picked.id }
        let made = tabs.filter { kept.contains($0.id) }.map { item(for: $0, prefs: prefs) }
        let shown = chosen.flatMap { id in made.first { $0.id == id } }
        return Shown(item: shown, items: made)
    }

    private func item(for tab: Tab, prefs: Preferences) -> Item {
        let report = tab.sound.report
        let session = report.session
        let reading = report.reading
        let live = reading?.live ?? false
        let duration = live ? 0 : reading?.duration ?? 0
        let site = Dusk.host(of: tab.pageAddress).map(Address.withoutWWW) ?? ""
        let now = Date()
        var playing = tab.sound.playing
        let rate = reading?.rate ?? 1
        var position = duration > 0 ? MiniPosition(time: reading?.time ?? 0, duration: duration, rate: rate,
                                                   playing: playing, at: tab.sound.at) : nil
        if let hold = holds[tab.id] {
            if hold.holds(against: reading, now: now), let held = position {
                position = hold.position(duration: held.duration, rate: rate)
                playing = hold.playing ?? playing
            } else {
                holds[tab.id] = nil
            }
        }
        let refused = report.refused > 0
        if refused || asked[tab.id].map({ now.timeIntervalSince($0.at) >= MiniHold.rateLongest }) == true { asked[tab.id] = nil }
        let reachable = reading?.element ?? false
        let long = MiniRule.long(actions: session.actions, duration: duration, live: live)
        let fetched = art(session.art, shy: tab.shy)
        let icon = tab.icon.flatMap { $0.isTemplate ? nil : $0 }
        return Item(
            id: tab.id,
            title: session.title.isEmpty ? MiniRule.bare(tab.label) : session.title,
            detail: session.artist.isEmpty ? site : session.artist,
            site: site,
            art: fetched,
            playing: playing,
            pair: MiniRule.pair(actions: session.actions, duration: duration, live: live, spoken: prefs.miniSpoken),
            previous: session.actions.contains(MiniAction.previous.rawValue),
            next: session.actions.contains(MiniAction.next.rawValue),
            position: position,
            live: live,
            rate: MiniRule.rateShown(reading: rate, asked: asked[tab.id], refused: refused, now: now),
            speed: MiniRule.speed(long: long, element: reachable, refused: refused, on: prefs.miniSpeed) && position != nil,
            seekable: position != nil && (reachable || session.actions.contains(MiniAction.seek.rawValue)),
            muted: tab.muted,
            skip: prefs.miniSkip,
            waiting: fetched == nil && !session.art.isEmpty && !tab.shy && fetching.contains(session.art) && artwork[session.art] == nil
                && !failed.contains(session.art),
            icon: icon
        )
    }

    private func art(_ address: String, shy: Bool) -> NSImage? {
        guard !address.isEmpty else { return nil }
        if let kept = artwork[address] { return kept }
        guard !shy, !fetching.contains(address), let url = URL(string: address) else { return nil }
        fetching.insert(address)
        if url.scheme == "data" {
            if let data = try? Data(contentsOf: url), data.count < 4_000_000, let image = NSImage(data: data) { keep(image, for: address) }
            return artwork[address]
        }
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        Task { [weak self] in
            guard let (data, _) = try? await Self.session.data(from: url), data.count < 4_000_000,
                  let image = NSImage(data: data) else {
                self?.failed.insert(address)
                self?.artTurn += 1
                return
            }
            self?.keep(image, for: address)
            self?.artTurn += 1
        }
        return nil
    }

    private func keep(_ image: NSImage, for address: String) {
        if artwork.count > 16 {
            artwork.removeAll()
            fetching.removeAll()
        }
        artwork[address] = image
    }

    private func tab(_ id: Tab.ID?) -> Tab? {
        guard let browser, let id = id ?? item?.id else { return nil }
        return (browser.tabs + browser.parkedTabs).first { $0.id == id }
    }

    func run(_ action: String, _ value: Double = 0, on id: Tab.ID? = nil) {
        guard let tab = tab(id), let web = tab.built else { return }
        if action == MiniAction.play.rawValue || action == MiniAction.pause.rawValue { holds[tab.id]?.playing = nil }
        let frame = tab.soundFrame
        web.evaluateJavaScript(MiniScripts.act(action, value), in: frame, in: .page) { result in
            let how = (try? result.get()) as? String ?? ""
            MainActor.assumeIsolated {
                if how.isEmpty, action == MiniAction.pause.rawValue {
                    web.setAllMediaPlaybackSuspended(true, completionHandler: nil)
                    tab.holdSound(true)
                } else if action == MiniAction.play.rawValue, tab.sound.held {
                    tab.holdSound(false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    web.evaluateJavaScript(MiniScripts.refresh, in: frame, in: Web.world) { _ in }
                }
            }
        }
    }

    func toggle(_ id: Tab.ID? = nil) {
        guard let shown = items.first(where: { $0.id == (id ?? item?.id) }) else { return }
        run(shown.playing ? MiniAction.pause.rawValue : MiniAction.play.rawValue, on: shown.id)
    }

    func track(next: Bool, on id: Tab.ID? = nil) {
        run(next ? MiniAction.next.rawValue : MiniAction.previous.rawValue, on: id)
    }

    func skip(back: Bool, on id: Tab.ID? = nil) {
        let step = Double(browser?.prefs.miniSkip ?? MiniRule.skipDefault)
        run("skip", back ? -step : step, on: id)
    }

    func seek(to fraction: Double, on id: Tab.ID? = nil) {
        guard let shown = items.first(where: { $0.id == (id ?? item?.id) }), let position = shown.position else { return }
        let target = max(0, min(1, fraction)) * position.duration
        let hold = MiniHold(time: target, at: Date(), playing: shown.playing)
        if surface || staged != nil {
            var moved = shown
            moved.position = MiniPosition(time: target, duration: position.duration, rate: position.rate, playing: position.playing, at: hold.at)
            if surface {
                items = [moved]
                item = moved
            } else {
                staged = moved
                publish(reckon())
            }
            return
        }
        holds[shown.id] = hold
        publish(reckon())
        bump()
        run(MiniAction.seek.rawValue, target, on: shown.id)
        for wait in [MiniHold.settle, MiniHold.longest] {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in self?.bump() }
        }
    }

    func speed(_ rate: Double, on id: Tab.ID? = nil) {
        guard let tab = tab(id), let web = tab.built, tab.sound.report.refused == 0 else { return }
        let rate = Tempo.rounded(Tempo.clamped(rate))
        asked[tab.id] = (rate, Date())
        bump()
        web.evaluateJavaScript(VideoSpeed.said, in: tab.soundFrame, in: Web.world) { _ in }
        run("rate", rate, on: tab.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + MiniHold.rateLongest + 0.05) { [weak self] in self?.bump() }
    }

    func open(_ id: Tab.ID? = nil) {
        guard let browser, let tab = tab(id) else { return }
        tab.holdSound(false)
        browser.bring(tab)
    }

    func dismiss(_ id: Tab.ID? = nil) {
        if staged != nil {
            staged = nil
            return
        }
        guard let tab = tab(id) else { return }
        dismissed[tab.id] = tab.sound.started
        if picked?.id == tab.id { picked = nil }
        bump()
    }

    func choose(_ id: Tab.ID) {
        guard let tab = tab(id) else { return }
        picked = (id, Date().timeIntervalSinceReferenceDate)
        if dismissed[tab.id] != nil { dismissed[tab.id] = nil }
        bump()
    }

    func mute(_ id: Tab.ID? = nil) {
        tab(id)?.toggleMute()
        bump()
    }

    private func bump() {
        artTurn += 1
    }
}

extension MiniPlayer {
    static func told(_ tab: Tab, in browser: Browser) -> [String: Any]? {
        let item = browser.mini.items.first { $0.id == tab.id }
        guard item != nil || !tab.soundFrames.isEmpty else { return nil }
        func clock(_ seconds: Double) -> String { MiniRule.clock(seconds) }
        func seconds(_ value: Double) -> String { value < 0 ? "live" : value > 0 ? clock(value) : "unknown" }
        var out: [String: Any] = [:]
        if let item {
            out["title"] = item.title
            out["detail"] = item.detail
            out["playing"] = item.playing
            out["shown"] = browser.mini.item?.id == item.id
            out["time"] = Int(item.position?.elapsed(now: Date()) ?? 0)
            out["duration"] = Int(item.position?.duration ?? 0)
            out["rate"] = item.rate
            out["speed"] = item.speed
        }
        let report = tab.sound.report
        if let reading = report.reading {
            out["reading"] = "\(reading.source), \(clock(reading.time)) of \(reading.live ? "live" : clock(reading.duration)), "
                + "\(VideoSpeed.label(reading.rate)), \(reading.playing ? "playing" : "paused")"
            out["chosen"] = reading.why
        } else {
            out["reading"] = "none"
        }
        out["reported"] = report.reported.map { "\(clock($0.time)) of \(clock($0.duration)) at \(VideoSpeed.label($0.rate))" } ?? "none"
        out["refused"] = report.refused > 0 ? VideoSpeed.label(report.refused) : "no"
        out["frames"] = tab.soundFrames.count
        out["frame"] = tab.soundFrame == nil ? "main" : "inner"
        for (index, media) in report.media.enumerated() {
            out["media\(index + 1)"] = [media.kind, media.picture ? "picture" : "", seconds(media.duration), "at \(clock(media.time))", media.paused ? "paused" : "playing",
                                        media.muted ? "muted" : "sound", media.loop ? "loops" : "once", media.loose ? "outside the page" : "",
                                        media.chosen ? "chosen" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return out
    }
}
