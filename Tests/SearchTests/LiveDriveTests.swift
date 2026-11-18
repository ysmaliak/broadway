import Foundation
import Testing
@testable import Search

@MainActor
struct LiveDriveTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let harbour = "1HarbourLightsBudgetQ3xYz0123456789ab"
    static let tides = "1TideTablesForTheSpitWharf_9876543-zz"
    static let ferry = "1FerryTimetableWinterScan00112233445"
    static let charts = "1ChartRoomFolder0000000000000000000a"
    static let source = LiveDrive.source

    static func ms(_ hoursAgo: Double) -> Double { (now.timeIntervalSince1970 - hoursAgo * 3600) * 1000 }

    static func entry(_ id: String?, _ title: Any?, _ mime: Any?, hoursAgo: Double? = 2, link: Any? = nil, modified: Any? = nil) -> [Any] {
        var fields = [Any](repeating: NSNull(), count: 115)
        fields[0] = id ?? NSNull()
        fields[2] = title ?? NSNull()
        fields[3] = mime ?? NSNull()
        fields[10] = modified ?? hoursAgo.map(ms) ?? NSNull()
        fields[114] = link ?? NSNull()
        return fields
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\x27")
            .replacingOccurrences(of: "\"", with: "\\x22").replacingOccurrences(of: "/", with: "\\/")
            .replacingOccurrences(of: "<", with: "\\x3c")
    }

    static func script(_ entries: [[Any]], form: String = "window['_DRIVE_ivd'] = '", tail: [Any] = [NSNull(), "en"]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [entries] + tail)
        return "var a = 1;" + form + escaped(String(decoding: data, as: UTF8.self)) + (form.hasSuffix("\"") ? "\";" : "';") + "var b = 2;"
    }

    static let three: [[Any]] = [
        entry(tides, "Tide tables for the spit", "application/vnd.google-apps.spreadsheet", hoursAgo: 5),
        entry(harbour, "Harbour lights budget", "application/vnd.google-apps.document", hoursAgo: 2,
              link: "https://docs.google.com/document/d/\(harbour)/edit?usp=drivesdk"),
        entry(ferry, "Ferry timetable, winter", "application/pdf", hoursAgo: 30),
    ]

    static func look(_ script: String?, landed: String = "https://drive.google.com/drive/recent", status: Int? = 200,
                     headers: [String: String] = [:]) -> LiveDrive.Look {
        LiveDrive.Look(landed: URL(string: landed), status: status, headers: headers, script: script)
    }

    static func answer(_ look: LiveDrive.Look) -> LiveReader.Answer { LiveDrive.answer(look, source: source, now: now) }

    @Test func aDriveFolderIsAPageFolderOfTheRecentView() {
        #expect(Self.source.kind == .page)
        #expect(Self.source.service == .drive)
        #expect(Self.source.siteName == "Google Drive")
        #expect(LiveDrive.reads(Self.source))
        #expect(LiveDrive.reads(LiveSource(kind: .page, address: "https://drive.google.com/drive/u/1/recent")))
        #expect(!LiveDrive.reads(LiveSource(kind: .page, address: "https://drive.google.com/drive/my-drive")))
        #expect(!LiveDrive.reads(LiveSource(kind: .feed, address: LiveDrive.recent)))
        #expect(Self.source.nothingWording == "No recent files")
        #expect(Self.source.heavy && !LiveSource.pullRequests.heavy)
    }

    @Test func threeFilesReadNewestFirstWithTheirKindAndAge() {
        guard case .read(let read) = Self.answer(Self.look(Self.script(Self.three))) else { Issue.record("not a read"); return }
        #expect(read.items.map(\.title) == ["Harbour lights budget", "Tide tables for the spit", "Ferry timetable, winter"])
        #expect(read.items.map(\.label) == ["Doc", "Sheet", "PDF"])
        #expect(read.items[0].key == "https://docs.google.com/document/d/\(Self.harbour)/edit?usp=drivesdk")
        #expect(read.items[1].key == "https://docs.google.com/spreadsheets/d/\(Self.tides)/edit")
        #expect(read.items[2].key == "https://drive.google.com/file/d/\(Self.ferry)/view")
        #expect(LiveDocuments.byline(read.items[0], now: Self.now) == "Doc · Edited 2 hours ago")
        #expect(LiveDocuments.byline(read.items[2], now: Self.now) == "PDF · Edited 30 hours ago")
        #expect(LiveDocuments.spoken(read.items[1], now: Self.now) == "Sheet, edited 5 hours ago")
        #expect(read.whole && !read.marked && read.more == nil)
    }

    @Test func eitherQuoteAndNoSpacesAreTheSameAssignment() {
        let plain = Self.answer(Self.look(Self.script(Self.three)))
        #expect(Self.answer(Self.look(Self.script(Self.three, form: "window['_DRIVE_ivd']='"))) == plain)
        #expect(Self.answer(Self.look(Self.script(Self.three, form: "window[\"_DRIVE_ivd\"] = \""))) == plain)
        #expect(Self.answer(Self.look("if (window['_DRIVE_ivd'] == null) {}" + Self.script(Self.three))) == plain)
    }

    @Test func foldersAndShortcutsAreNotRows() {
        let entries = Self.three + [Self.entry(Self.charts, "Chart room", "application/vnd.google-apps.folder", hoursAgo: 1),
                                    Self.entry("1ShortcutToTheChartRoom000000000000", "Chart room", "application/vnd.google-apps.shortcut", hoursAgo: 1)]
        #expect(Self.answer(Self.look(Self.script(entries))).found?.count == 3)
    }

    @Test func theRecentViewsOwnEmptyListIsAProvenEmptyRead() {
        guard case .read(let read) = Self.answer(Self.look(Self.script([]))) else { Issue.record("not a read"); return }
        #expect(read.items.isEmpty && read.marked)
    }

    @Test func aListPastTheCapSaysMoreOnGoogleDrive() {
        let many = (0..<15).map { Self.entry(String(format: "1LongListOfFilesNumber%014d", $0), "Logbook page \($0)", "application/vnd.google-apps.document",
                                             hoursAgo: Double($0) + 1) }
        guard case .read(let read) = Self.answer(Self.look(Self.script(many))) else { Issue.record("not a read"); return }
        #expect(read.items.count == Self.source.cap)
        #expect(read.more == LiveDrive.recent)
        #expect(read.items.first?.title == "Logbook page 0")
    }

    @Test func signInConsentAndTheAccountChooserAreSignedOut() {
        for landed in ["https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fdrive.google.com%2Fdrive%2Frecent",
                       "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fdrive.google.com%2Fdrive%2Frecent",
                       "https://consent.google.com/m?continue=https://drive.google.com/drive/recent",
                       "https://workspace.google.com/products/drive/"] {
            #expect(Self.answer(Self.look(nil, landed: landed)) == .signIn, "\(landed)")
            #expect(Self.answer(Self.look(Self.script(Self.three), landed: landed)) == .signIn, "\(landed)")
        }
    }

    @Test func errorsAndLimitsAreNotLists() {
        #expect(Self.answer(Self.look("<p>Server Error</p>", status: 500)) == .failed)
        #expect(Self.answer(Self.look(Self.script(Self.three), status: 500)) == .failed)
        #expect(Self.answer(Self.look(nil, status: 429, headers: ["Retry-After": "120"])) == .missed(LiveMiss(cause: .limited, wait: 120)))
        #expect(Self.answer(Self.look(nil, status: 429)) == .missed(LiveMiss(cause: .limited)))
        #expect(Self.answer(Self.look(Self.script(Self.three), landed: "https://www.google.com/drive/")) == .failed)
    }

    @Test func anEmptyAnswerWithoutTheViewsOwnListIsRefused() {
        #expect(Self.answer(Self.look(nil)) == .failed)
        #expect(Self.answer(Self.look("")) == .failed)
        #expect(Self.answer(Self.look("window['_DRIVE_ivd'] = '';")) == .failed)
        #expect(Self.answer(Self.look("window['_DRIVE_ivd'] = '[]';")) == .failed)
        #expect(Self.answer(Self.look("window['_DRIVE_ivd'] = '{\\x22files\\x22:[]}';")) == .failed)
        #expect(Self.answer(Self.look("window['_DRIVE_ivd'] = '[[]")) == .failed)
    }

    @Test func oneFileWithAFieldMissingOrRenamedRefusesTheWholeRead() {
        let wrong: [[Any]] = [
            Self.entry(Self.harbour, nil, "application/vnd.google-apps.document"),
            Self.entry(Self.harbour, "   ", "application/vnd.google-apps.document"),
            Self.entry(Self.harbour, "Harbour lights budget", nil),
            Self.entry(Self.harbour, "Harbour lights budget", 42),
            Self.entry(Self.harbour, "Harbour lights budget", "Google Docs"),
            Self.entry(nil, "Harbour lights budget", "application/vnd.google-apps.document"),
            Self.entry("short", "Harbour lights budget", "application/vnd.google-apps.document"),
            Self.entry(Self.harbour, "Harbour lights budget", "application/vnd.google-apps.document", hoursAgo: nil),
            Self.entry(Self.harbour, "Harbour lights budget", "application/vnd.google-apps.document", modified: Self.now.timeIntervalSince1970 - 7200),
            Self.entry(Self.harbour, "Harbour lights budget", "application/vnd.google-apps.document", modified: "1799992800000"),
            Self.entry(Self.harbour, "Harbour lights budget", "application/vnd.google-apps.document", modified: true),
            Self.entry(Self.harbour, "Harbour lights budget", "application/vnd.google-apps.document",
                       link: "https://docs.google.com/document/d/\(Self.tides)/edit"),
            Self.entry(Self.harbour, "Harbour lights budget", "application/vnd.google-apps.document", link: 7),
        ]
        for bad in wrong {
            #expect(Self.answer(Self.look(Self.script(Self.three + [bad]))) == .failed)
        }
        #expect(Self.answer(Self.look(Self.script([[Self.harbour, "Harbour lights budget"]]))) == .failed)
        #expect(Self.answer(Self.look(Self.script([["not", "a", "file"]] as [[Any]]))) == .failed)
    }

    @Test func aTestWorldWithoutAStageNeverAsksGoogle() async {
        let settings = UserDefaults(suiteName: "live-drive-\(UUID().uuidString)")!
        let before = await LiveDriveLoad.loads
        let folder = LiveFolder(space: UUID(), name: "Recent Files", source: Self.source)
        let answer = await LiveDrive.read(folder, settings: settings, testing: true)
        #expect(answer == .failed)
        #expect(await LiveDriveLoad.loads == before)
        #expect(LiveDrive.stage(settings: settings, testing: true) == nil)
        settings.set("https://drive.google.com/", forKey: Integrations.rootKey)
        #expect(LiveDrive.stage(settings: settings, testing: true) == nil)
    }

    @Test func aDriveFolderIsReadNoMoreThanEveryQuarterHour() {
        let moment = LiveMoment(active: true, away: 0)
        var drive = LiveFolder(space: UUID(), name: "Recent Files", source: Self.source)
        var pulls = LiveFolder(space: UUID(), name: "PRs", source: .pullRequests)
        drive.read = Self.now.addingTimeInterval(-6 * 60)
        pulls.read = Self.now.addingTimeInterval(-6 * 60)
        #expect(LivePace.wanted([drive, pulls], moment: moment, looked: nil, returned: false, now: Self.now) == [pulls.id])
        drive.state = .failed
        #expect(LivePace.wanted([drive], moment: moment, looked: nil, returned: true, now: Self.now).isEmpty)
        drive.read = Self.now.addingTimeInterval(-16 * 60)
        #expect(LivePace.wanted([drive], moment: moment, looked: nil, returned: false, now: Self.now) == [drive.id])
    }

    @Test func driveIsOfferedInSettingsAndOnItsOwnPages() {
        #expect(LivePreset.all.contains { $0.title == "Google Drive" && $0.detail == "Files you opened lately" && $0.source == Self.source })
        for page in ["https://drive.google.com/drive/my-drive", "https://docs.google.com/document/d/\(Self.harbour)/edit"] {
            let spot = LiveSuggestions.spot(URL(string: page)!)
            #expect(spot?.id == "drive" && spot?.source == Self.source, "\(page)")
        }
        #expect(LiveOfferWords.gives(Self.source) == "Files you opened lately on Google Drive, kept up to date")
    }
}

struct LiveDocumentIdentityTests {
    let id = "1HarbourLightsBudgetQ3xYz0123456789ab"

    @Test func everyAddressOfOneDriveFileIsOneRow() {
        let forms = [
            "https://docs.google.com/document/d/\(id)/edit",
            "https://docs.google.com/document/d/\(id)/edit?usp=sharing",
            "https://docs.google.com/document/d/\(id)/edit?tab=t.0#heading=h.abc",
            "https://docs.google.com/document/d/\(id)",
            "https://docs.google.com/document/u/1/d/\(id)/edit",
            "https://docs.google.com/spreadsheets/d/\(id)/edit?gid=0#gid=0",
            "https://docs.google.com/presentation/d/\(id)/edit#slide=id.p",
            "https://docs.google.com/drawings/d/\(id)/edit",
            "https://docs.google.com/forms/d/\(id)/edit",
            "https://docs.google.com/file/d/\(id)/edit",
            "https://docs.google.com/open?id=\(id)",
            "https://drive.google.com/file/d/\(id)/view?usp=drive_link",
            "https://drive.google.com/file/u/0/d/\(id)/view",
            "https://drive.google.com/open?id=\(id)",
            "https://drive.google.com/uc?id=\(id)&export=download",
            "https://drive.google.com/drive/folders/\(id)",
            "https://drive.google.com/drive/u/2/folders/\(id)",
        ]
        for form in forms {
            #expect(LiveIdentity.of(form) == "drive:\(id)", "\(form)")
        }
        #expect(LiveIdentity.typed("drive:\(id)"))
    }

    @Test func otherDriveAddressesAreNotFiles() {
        let other = "1TideTablesForTheSpitWharf_9876543-zz"
        #expect(LiveIdentity.of("https://docs.google.com/document/d/\(other)/edit") != LiveIdentity.of("https://docs.google.com/document/d/\(id)/edit"))
        for page in ["https://docs.google.com/document/d/e/2PACX-1vQpublishedHarbourLightsBudget000/pub",
                     "https://docs.google.com/forms/d/e/1FAIpQLSeHarbourSurveyPublished000000/viewform",
                     "https://drive.google.com/drive/my-drive", "https://drive.google.com/drive/recent",
                     "https://docs.google.com/document/d/short/edit", "https://docs.google.com/document/",
                     "https://drive.google.com/open?id=short"] {
            #expect(!LiveIdentity.of(page).hasPrefix("drive:"), "\(page)")
        }
    }

    @Test func everyAddressOfOneNotionPageIsOneRow() {
        let hex = "1429989fe8ac4effbc8f57f56486db54"
        let block = "2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e"
        let forms = [
            "https://www.notion.so/\(hex)",
            "https://notion.so/acme/Harbour-lights-plan-\(hex)",
            "https://www.notion.so/acme/Harbour-lights-plan-\(hex)?pvs=4",
            "https://www.notion.so/Harbour-lights-plan-\(hex)#\(block)",
            "https://www.notion.so/1429989f-e8ac-4eff-bc8f-57f56486db54",
            "https://www.notion.so/Harbour-lights-plan-1429989f-e8ac-4eff-bc8f-57f56486db54",
            "https://app.notion.com/p/\(hex)",
            "https://app.notion.com/p/Harbour-lights-plan-\(hex)",
            "https://acme.notion.site/Harbour-lights-plan-\(hex)",
            "https://www.notion.so/acme/Harbour-lights-plan-\(hex.uppercased())",
        ]
        for form in forms {
            #expect(LiveIdentity.of(form) == "notion:\(hex)", "\(form)")
        }
        #expect(LiveIdentity.typed("notion:\(hex)"))
    }

    @Test func aNotionPeekAndOtherPagesStayApart() {
        let hex = "1429989fe8ac4effbc8f57f56486db54"
        let table = "9c8b7a6d5e4f40312a1b0c9d8e7f6a5b"
        let view = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        let peek = "https://www.notion.so/acme/\(table)?v=\(view)&p=\(hex)&pm=s"
        #expect(!LiveIdentity.of(peek).hasPrefix("notion:"))
        #expect(!LiveIdentity.same(peek, "https://www.notion.so/\(hex)"))
        #expect(!LiveIdentity.same(peek, "https://www.notion.so/\(table)"))
        for page in ["https://www.notion.so/acme", "https://www.notion.so/acme/Harbour-lights-plan-\(hex.dropLast())",
                     "https://www.notion.so/acme/Harbour\(hex)", "https://www.notion.so/Harbour-lights-plan-1429989fe8ac4effbc8f57f56486db5g",
                     "https://notion.example/\(hex)"] {
            #expect(!LiveIdentity.of(page).hasPrefix("notion:"), "\(page)")
        }
    }
}
