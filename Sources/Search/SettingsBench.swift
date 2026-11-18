import AppKit

@MainActor
enum SettingsBenchFaces {
    private static func page(_ build: (SettingsPageStack) -> Void) -> NSView {
        let page = SettingsPageStack()
        page.translatesAutoresizingMaskIntoConstraints = false
        page.widthAnchor.constraint(equalToConstant: 620).isActive = true
        build(page)
        page.layoutSubtreeIfNeeded()
        page.frame = NSRect(origin: .zero, size: page.fittingSize)
        return page
    }

    private static func card(_ page: SettingsPageStack, _ heading: String?, _ rows: [NSView]) {
        if let heading { page.add(SettingsHeading(heading)) }
        let card = SettingsCard()
        rows.forEach { card.add($0) }
        page.add(card, after: SettingsMetrics.sectionGap)
    }

    private static func toggle(_ on: Bool) -> KitSwitch {
        KitSwitch(isOn: on, small: true, system: true)
    }

    private static func pill(_ title: String) -> SettingsPill {
        SettingsPill(title)
    }

    static func make(_ name: String) -> NSView? {
        switch name {
        case "settings-switches":
            return page { page in
                card(page, "Tracking", [
                    SettingsRowView(id: "a", symbol: "shield.lefthalf.filled", title: "Block ads and trackers",
                                    detail: "Inside WebKit, before a request is made, and YouTube's ads", more: "More", control: toggle(true)),
                    SettingsRowView(id: "b", symbol: "eye.slash", title: "Prevent cross-site tracking",
                                    detail: "As in Safari. Private windows keep it on.", more: "More", control: toggle(false)),
                ])
            }
        case "settings-controls":
            return page { page in
                let lives = SettingsPopUp()
                lives.button.addItems(withTitles: TabLife.allCases.map(\.title))
                lives.button.selectItem(at: TabLife.allCases.firstIndex(of: .never) ?? 0)
                card(page, nil, [
                    SettingsRowView(id: "a", symbol: "key.viewfinder", title: "Your passwords", detail: "In the macOS keychain, shown with Touch ID",
                                    control: pill("Open")),
                    SettingsRowView(id: "b", symbol: "timer", title: "Tidy up old tabs",
                                    detail: "Pinned, named and grouped tabs stay. ⇧⌘T brings one back.", control: lives),
                    SettingsRowView(id: "c", symbol: "rectangle.and.text.magnifyingglass", title: "New tab opens",
                                    detail: "A page of its own, or a field floating over what you're reading",
                                    control: KitChoice("New tab opens", options: [.init(title: "Page"), .init(title: "Floating Field")], picked: 0)),
                ])
            }
        case "settings-drill":
            return page { page in
                let permissions = SettingsDrillRow(id: "a", symbol: "hand.raised", title: "Site Permissions",
                                                   line: "Camera, microphone, location, notifications and pop-ups") {}
                let languages = SettingsDrillRow(id: "b", symbol: SettingsDetail.languages.symbol, title: SettingsDetail.languages.title) {}
                languages.mark.show(count: 3, value: nil)
                card(page, "Sites", [permissions, languages])
            }
        case "settings-danger":
            return page { page in
                card(page, "Danger zone", [
                    SettingsDangerRow(id: "a", symbol: "clock.arrow.circlepath", title: "Clear History…", detail: "Every address you have been to") {},
                    SettingsDangerRow(id: "b", symbol: "person.crop.circle.badge.xmark", title: "Sign Out of Every Site…",
                                      detail: "Signs you out of every site") {},
                    SettingsDangerRow(id: "c", symbol: "internaldrive", title: "Clear Cache…", detail: "Only what was fetched to draw pages") {},
                ])
            }
        case "settings-header":
            let band = SettingsStageBand(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
            var scene = SettingsStageScene()
            scene.ads = .marked
            band.show(SettingsStageFacts(place: SettingsPlace(page: .privacy), title: SettingsPage.privacy.title,
                                         summary: SettingsPage.privacy.summary, crumb: nil,
                                         scene: scene, rest: .page))
            band.mark(.page)
            band.frame.size.height = band.measure(620)
            band.layoutSubtreeIfNeeded()
            return band
        default:
            return nil
        }
    }
}

@MainActor
enum SettingsPieceSurfaces {
    static let names = ["developer-servers", "quick-actions", "quick-action-sheet",
                        "shortcuts", "extensions-page", "store-offer", "controls-gallery"]

    static func size(_ request: [String: Any], _ width: Double, _ height: Double) -> CGSize {
        CGSize(width: request["width"] as? Double ?? width, height: request["height"] as? Double ?? height)
    }

    static func make(_ name: String, _ request: [String: Any]) -> NSView? {
        guard let browser = Browsers.all.first else { return nil }
        switch name {
        case "developer-servers":
            DeveloperSurface.servers(request)
            return paper(SettingsPieceForm { form in
                form.section("Local servers") { form.fitted(SettingsFormRow(DeveloperServersView(browser: browser))) }
            }, size(request, 650, 600))
        case "quick-actions":
            let store = QuickActionsSurface.fixture(request)
            return paper(QuickActionsForm(browser: Browsers.acting, store: store), size(request, 650, 520))
        case "quick-action-sheet":
            let store = QuickActionsSurface.fixture(request)
            let view = QuickActionSheetView(store: store, history: Browsers.acting.history,
                                            draft: QuickActionsSurface.draft(request, store: store))
            view.kitSize(width: view.frame.width, height: view.frame.height)
            return view
        case "shortcuts":
            let acting = Browsers.acting
            return paper(ShortcutsForm(browser: acting, store: .shared, prefs: acting.prefs), size(request, 650, 900))
        case "extensions-page":
            return paper(ExtensionsForm(browser: Browsers.acting), size(request, 650, 640))
        case "store-offer":
            let bar = StoreOfferView(busy: request["busy"] as? Bool ?? false, add: {})
            let stage = KitFlippedView()
            stage.kitPin(bar, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
            let fitted = bar.intrinsicContentSize
            stage.kitSize(width: fitted.width + 24, height: fitted.height + 24)
            return stage
        case "controls-gallery":
            let gallery = BroadwayGallery(ground: KitColor.ground)
            gallery.kitSize(width: gallery.frame.width, height: gallery.frame.height)
            return gallery
        default:
            return nil
        }
    }

    private static func paper(_ form: SettingsForm, _ size: CGSize) -> NSView {
        let stage = KitBox(fill: SettingsMetrics.ground)
        stage.frame = NSRect(origin: .zero, size: size)
        stage.layer?.masksToBounds = true
        stage.kitSize(width: size.width, height: size.height)
        form.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            form.topAnchor.constraint(equalTo: stage.topAnchor),
        ])
        stage.layoutSubtreeIfNeeded()
        stage.layoutSubtreeIfNeeded()
        return stage
    }
}

@MainActor
final class SettingsPieceForm: SettingsForm {
    private let fill: (SettingsForm) -> Void

    init(_ fill: @escaping (SettingsForm) -> Void) {
        self.fill = fill
        super.init()
        load()
    }

    override func build() { fill(self) }
}
