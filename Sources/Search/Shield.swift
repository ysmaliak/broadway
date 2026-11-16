import Combine
import Observation
import WebKit

// The ad blocker. No settings, no counter, no shield icon going green — it is
// compiled once at launch and then it is simply true that the page is lighter.
//
// A content rule list is enforced inside WebKit's networking, before a request
// is made and before a stylesheet is applied, so this costs nothing at run time
// in the way a JavaScript blocker does.

@MainActor
@Observable
final class Shield {
    static let shared = Shield()

    @ObservationIgnored private(set) var always: WKContentRuleList?
    @ObservationIgnored private(set) var fallback: WKContentRuleList?
    @ObservationIgnored private(set) var downloaded: [WKContentRuleList] = []

    private final class Seat {
        var host: String?
        var lists: [WKContentRuleList] = []
    }

    private let seats = NSMapTable<WKUserContentController, Seat>.weakToStrongObjects()

    var offer: String?
    @ObservationIgnored private var reloads: [String: [Date]] = [:]
    @ObservationIgnored private var offered: Set<String> = []

    /// Set the one time compiling the list didn't work. The toggle in
    /// Settings can say "on" all it wants; nothing is actually blocked until
    /// this is nil, so it is the one thing worth telling a person about
    /// rather than failing the quiet way a missing ad is quiet.
    private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    @ObservationIgnored var enabled = true

    /// Sites it is off for — the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
        fitAll()
    }

    /// Before each page: the list goes on or off for the site this tab is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation is what makes "off for this site" true
    /// for the whole page rather than for the second half of it.
    func tune(_ controller: WKUserContentController, for host: String?) {
        let seat = seats.object(forKey: controller) ?? Seat()
        seat.host = host
        seats.setObject(seat, forKey: controller)
        fit(controller, seat)
    }

    private var lists: [WKContentRuleList] {
        let own = downloaded.isEmpty ? [fallback] : []
        return ([always] + own).compactMap { $0 } + downloaded
    }

    private func fit(_ controller: WKUserContentController, _ seat: Seat) {
        let wanted = enabled && !isPaused(on: seat.host) ? lists : []
        guard wanted.map(\.identifier) != seat.lists.map(\.identifier) else { return }
        let keep = Set(wanted.map(\.identifier))
        let have = Set(seat.lists.map(\.identifier))
        for list in seat.lists where !keep.contains(list.identifier) { controller.remove(list) }
        for list in wanted where !have.contains(list.identifier) { controller.add(list) }
        seat.lists = wanted
    }

    private func fitAll() {
        for case let controller as WKUserContentController in seats.keyEnumerator().allObjects {
            if let seat = seats.object(forKey: controller) { fit(controller, seat) }
        }
    }

    func use(_ lists: [WKContentRuleList]) {
        downloaded = lists
        fitAll()
    }

    static func offersAfter(_ times: [Date], now: Date) -> Bool {
        times.filter { now.timeIntervalSince($0) <= 20 }.count >= 3
    }

    func reloaded(_ host: String?, at now: Date = Date()) {
        guard enabled, let host, !isPaused(on: host), !offered.contains(host) else { return }
        let times = (reloads[host] ?? []).filter { now.timeIntervalSince($0) <= 20 } + [now]
        reloads[host] = times
        guard Shield.offersAfter(times, now: now) else { return }
        offered.insert(host)
        offer = host
    }

    /// Third parties whose only job is to watch or to sell. First-party
    /// requests are untouched: a site's own scripts are the site.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
        "2mdn.net", "adform.net", "adition.com", "adcolony.com", "adsafeprotected.com",
        "adtechus.com", "advertising.com", "bluekai.com", "crwdcntrl.net", "demdex.net",
        "doubleverify.com", "everesttech.net", "exelator.com", "eyeota.net", "gumgum.com",
        "imrworldwide.com", "inmobi.com", "krxd.net", "lijit.com", "liadm.com", "mathtag.com",
        "media.net", "mgid.com", "ml314.com", "mookie1.com", "nativo.com", "nr-data.net",
        "omtrdc.net", "owneriq.net", "rfihub.com", "revcontent.com", "rlcdn.com",
        "serving-sys.com", "sonobi.com", "spotxchange.com", "tapad.com", "tremorhub.com",
        "turn.com", "yieldmo.com", "zedo.com", "zemanta.com",
    ]

    /// The few slots that are reliably an advertisement and nothing else. Kept
    /// deliberately short — a generous cosmetic list is how a blocker starts
    /// eating the page it was meant to clean.
    ///
    /// The second half are the boxes a site keeps open for the ad while it
    /// loads: with the ad blocked they stay, empty, a banner's height of
    /// nothing (#159). Each is a whole class name from EasyList's generic
    /// hiding list, matched as a whole word: an element whose class is
    /// `ad-slot` goes, one whose class merely contains "ad" stays.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
        ".ad-slot", ".ad-slot-container", ".top-banner-ad-container",
        ".ad-leaderboard", ".ad-billboard", ".ad-giga", ".ad-mpu", ".ad-mrec",
        ".ad-unit", ".adunit", ".adslot", ".dfp-ad", ".gpt-ad", ".w_ad",
    ]

    /// Slots with names too plain, or too much a site's own, to hide
    /// everywhere — AS and El País call theirs just `.ad` — hidden only on
    /// the sites EasyList's own site rules hide them on.
    private static let slotsBySite: [(sites: [String], selector: String)] = [
        (["*as.com", "*elpais.com"], ".ad"),
        (["*theguardian.com"], ".top-fronts-banner-ad-container"),
        (["*independent.co.uk", "*the-independent.com"], "#billboard-wrapper"),
        (["*cnn.com"], ".ad-slot-header__wrapper"),
    ]

    static func networkFilter(for domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        // WebKit's canonical HTTP URLs end the host with a port or a slash.
        return "^https?://([^/]+\\.)?\(escaped)[:/]"
    }

    static let store: WKContentRuleListStore? = {
        let folder = Store.file("Shield")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: folder)
    }()

    static let signInScripts = [
        "^https?://connect\\.facebook\\.net/[^/]+/sdk\\.js",
        "^https?://connect\\.facebook\\.net/[^/]+/bundle/sdk\\.js",
    ]

    static var ownRules: [[String: Any]] {
        var rules: [[String: Any]] = Shield.unwanted.map { domain in
            return [
                "trigger": [
                    "url-filter": Shield.networkFilter(for: domain),
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules += Shield.signInScripts.map { filter in
            ["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Shield.slots.joined(separator: ", ")],
        ])
        rules += Shield.slotsBySite.map { entry in
            [
                "trigger": ["url-filter": ".*", "if-domain": entry.sites],
                "action": ["type": "css-display-none", "selector": entry.selector],
            ]
        }
        return rules
    }

    func compile() {
        guard always == nil || fallback == nil else { return }
        trouble = nil
        // YouTube's ad reports and ad paths (see YouTubeAds.swift).
        compile("broadway-shield-youtube", YouTubeAds.rules) { [weak self] in self?.always = $0 }
        compile("broadway-shield-fallback", Shield.ownRules) { [weak self] in
            self?.fallback = $0
            ShieldLists.shared.start()
        }
    }

    private func compile(_ identifier: String, _ rules: [[String: Any]], then: @escaping (WKContentRuleList) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else {
            trouble = "Couldn't build the block list"
            return
        }
        guard let store = Shield.store else {
            trouble = "Couldn't find a place to save the block list"
            return
        }
        store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        ) { [weak self] compiled, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let compiled else {
                    self.trouble = error?.localizedDescription ?? "Couldn't compile the block list"
                    return
                }
                then(compiled)
                // Tabs that opened while this was still compiling get it now.
                self.fitAll()
            }
        }
    }

    func protect(_ controller: WKUserContentController) {
        let seat = seats.object(forKey: controller) ?? Seat()
        seats.setObject(seat, forKey: controller)
        fit(controller, seat)
    }

    /// Switched on or off for every page that is already open.
    func applyEverywhere() { fitAll() }
}
