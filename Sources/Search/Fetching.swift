import AppKit
import Combine
import Observation
import WebKit

/// A download visible in the Downloads panel. Resume data and the cookie
/// store it was asked with live only for this process; neither is part of
/// the saved history.
@MainActor
@Observable
final class FetchEntry: Identifiable {
    enum State: Equatable {
        case downloading
        case pausing
        case paused
        case resuming
        case failed
    }

    enum StopAction: Equatable {
        case pause
        case cancel
    }

    let id = UUID()
    private(set) var state: State = .downloading
    private(set) var name: String
    private(set) var fraction: Double?
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var errorDescription: String?

    private struct PartialFileVersion: Equatable {
        let volume: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    var canPause: Bool { state == .downloading && request.map(Self.replayable) == true }
    var canResume: Bool {
        (state == .paused || state == .failed) && resumeData != nil && store != nil
            && request.map(Self.replayable) != false
    }
    /// Asked again from the start: only a plain GET or HEAD. A download a
    /// form sent (a POST, a body) would send the form again.
    var canRetry: Bool { state == .failed && store != nil && request.map(Self.replayable) == true }

    static func replayable(_ request: URLRequest) -> Bool {
        ["GET", "HEAD"].contains((request.httpMethod ?? "GET").uppercased())
            && request.httpBody == nil && request.httpBodyStream == nil
    }

    // These are deliberately in-memory only. The store carries the cookies
    // the download was asked with, and a resume or retry asks with the same
    // ones: a private tab's never reach the others, nor theirs a private one.
    var resumeData: Data?
    var request: URLRequest?
    /// The page's own view while it is there; the row never keeps it, nor
    /// its web process, alive once its tab has closed.
    weak var webView: WKWebView?
    private(set) var store: WKWebsiteDataStore?
    var destination: URL?
    /// The name asked for, before " 2" and so on: a retry is numbered afresh.
    var retryName: String
    var download: WKDownload?
    var pendingStop: StopAction?
    var operationID = UUID()
    private var destinationWasAbsent: Bool?
    private var partialFileVersion: PartialFileVersion?

    init(name: String, request: URLRequest?, webView: WKWebView?) {
        self.name = name
        self.retryName = name
        self.request = request
        self.webView = webView
        self.store = webView?.configuration.websiteDataStore
    }

    func began(_ download: WKDownload, operationID: UUID? = nil) {
        if let operationID, self.operationID != operationID { return }
        self.download = download
        pendingStop = nil
        resumeData = nil
        errorDescription = nil
        state = .downloading
        self.operationID = UUID()
    }

    func record(_ progress: Progress, trackFile: Bool = true) {
        completedBytes = max(0, progress.completedUnitCount)
        totalBytes = max(0, progress.totalUnitCount)
        fraction = totalBytes > 0
            ? min(1, max(0, Double(completedBytes) / Double(totalBytes)))
            : nil
        if trackFile { trackPartialFile() }
    }

    /// At a terminal callback progress can be ahead of the last queued KVO
    /// measurement. Refresh size and date only for a file identity already
    /// claimed during active progress; never claim an unknown path here.
    func recordTerminal(_ progress: Progress) {
        record(progress, trackFile: false)
        guard destinationWasAbsent == true, let destination,
              let expected = partialFileVersion,
              let current = Self.partialFileVersion(at: destination),
              current.volume == expected.volume, current.inode == expected.inode else { return }
        partialFileVersion = current
    }

    func reached(_ file: URL) {
        if destination != file {
            destinationWasAbsent = !FileManager.default.fileExists(atPath: file.path)
            partialFileVersion = nil
        } else if destinationWasAbsent == nil {
            destinationWasAbsent = !FileManager.default.fileExists(atPath: file.path)
        }
        destination = file
        name = file.lastPathComponent
    }

    /// The output URL is initially required to be absent. Claim it only after
    /// WebKit reports real byte progress, then keep the latest file identity
    /// observed during that transfer. Discard paths only while that identity,
    /// size and modification time still match.
    func discardOwnedPartialFile() {
        guard destinationWasAbsent == true, let destination,
              let expected = partialFileVersion,
              Self.partialFileVersion(at: destination) == expected else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    /// Whether a resume would go on writing the file this download began and
    /// nothing else: WebKit appends to whatever is at the path. A file put
    /// there meanwhile, or the partial one changed, and it starts over instead.
    var partialFileIsOurs: Bool {
        guard let destination else { return true }
        let current = Self.partialFileVersion(at: destination)
        guard let expected = partialFileVersion else { return current == nil }
        return destinationWasAbsent == true && current == expected
    }

    /// The partial file is not ours any more: its resume data is let go, and
    /// only Retry, to a name of its own, is left.
    func lostPartialFile() {
        resumeData = nil
        errorDescription = "The file changed while the download was paused"
        state = .failed
    }

    func stopped(_ action: StopAction, data: Data?) {
        download = nil
        pendingStop = nil
        resumeData = action == .pause ? data : nil
        if action == .cancel {
            clear()
            return
        }
        if data != nil {
            errorDescription = nil
            state = .paused
        } else {
            // WKDownload explicitly returns nil when its server cannot
            // produce resume data. Retry stays, where it may.
            errorDescription = "The server doesn't support pausing this download"
            state = .failed
        }
    }

    func failed(_ error: Error, resumeData: Data?) {
        download = nil
        pendingStop = nil
        self.resumeData = resumeData
        errorDescription = Self.reason(for: error)
        state = .failed
    }

    func preparingToStop(_ action: StopAction) -> UUID {
        state = .pausing
        pendingStop = action
        operationID = UUID()
        return operationID
    }

    func preparingToStart(destination: URL? = nil) -> UUID {
        state = .resuming
        errorDescription = nil
        // A retry writes a file of its own, even at the same path: nothing
        // claimed for the last attempt is claimed for this one.
        if let destination {
            self.destination = destination
            destinationWasAbsent = nil
            partialFileVersion = nil
        }
        operationID = UUID()
        return operationID
    }

    func resetProgress() {
        fraction = 0
        completedBytes = 0
        totalBytes = 0
    }

    func clear() {
        resumeData = nil
        request = nil
        webView = nil
        store = nil
        destination = nil
        destinationWasAbsent = nil
        partialFileVersion = nil
        download = nil
        pendingStop = nil
        operationID = UUID()
        errorDescription = nil
        fraction = nil
        completedBytes = 0
        totalBytes = 0
    }

    private static func reason(for error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The download failed for an unknown reason" : text
    }

    private func trackPartialFile() {
        guard completedBytes > 0, destinationWasAbsent == true, let destination,
              let current = Self.partialFileVersion(at: destination) else { return }
        if let previous = partialFileVersion,
           (previous.volume != current.volume || previous.inode != current.inode) {
            return
        }
        partialFileVersion = current
    }

    private static func partialFileVersion(at url: URL) -> PartialFileVersion? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return PartialFileVersion(volume: volume, inode: inode, size: size, modified: modified)
    }
}

// Downloads, seen while they happen. Successful files are recorded by Loot;
// these entries only describe active and recoverable downloads.
@MainActor
@Observable
final class Fetches {
    private(set) var entries: [FetchEntry] = []

    /// A running download, or one just done: the circle is up.
    private(set) var showing = false
    /// How far the running ones are, together; nil while none says its size.
    private(set) var fraction: Double?
    /// Everything finished, and the circle says so for a moment before it goes.
    private(set) var done = false
    @ObservationIgnored private weak var loot: Loot?
    var waiting: Bool {
        guard let loot else { return false }
        return loot.kept.contains { $0.date > loot.clearedAt }
    }

    init(loot: Loot = Shared.loot) {
        self.loot = loot
    }

    func cleared() {
        guard running.isEmpty else { return }
        leaving?.cancel()
        showing = false
        done = false
        fraction = nil
    }

    /// How long the circle stays once the last download is in.
    static let linger: TimeInterval = 5

    struct StopOperation {
        let download: WKDownload
        let entry: FetchEntry?
        let operationID: UUID
    }

    struct StartOperation {
        let entry: FetchEntry
        /// The page's view if it is still there; otherwise one made for this
        /// attempt on the same store, kept only until the attempt ends.
        let webView: WKWebView
        let helper: Bool
        let request: URLRequest?
        let resumeData: Data?
        let operationID: UUID
    }

    struct Ended {
        let owner: Browser
        let announceFailure: Bool
    }

    private final class Running {
        let download: WKDownload
        let entry: FetchEntry?
        // WKDownload.delegate is weak. Keep its Browser alive while it needs
        // to receive callbacks, then release it as soon as the attempt stops.
        let owner: Browser
        /// The view made for a resume or retry, whose page is gone: kept for
        /// this attempt only. A tab's own view is never kept here.
        let helper: WKWebView?
        let listed: Bool
        var watch: NSKeyValueObservation?
        var shown: Progress?
        var stopAction: FetchEntry.StopAction?
        var operationID = UUID()

        init(_ download: WKDownload, entry: FetchEntry?, owner: Browser, helper: WKWebView?, listed: Bool) {
            self.download = download
            self.entry = entry
            self.owner = owner
            self.helper = helper
            self.listed = listed
        }
    }

    private var running: [ObjectIdentifier: Running] = [:]
    private var leaving: DispatchWorkItem?

    /// A download has begun. Private downloads are tracked for cleanup and
    /// aggregate progress, but never become entries in the shared panel.
    @discardableResult
    func start(
        _ download: WKDownload,
        owner: Browser,
        webView: WKWebView?,
        listed: Bool,
        entry continuing: FetchEntry? = nil,
        operationID: UUID? = nil,
        helper: WKWebView? = nil
    ) -> Bool {
        if let continuing, let operationID, continuing.operationID != operationID { return false }

        let entry: FetchEntry?
        if let continuing {
            continuing.request = continuing.request ?? download.originalRequest.map { $0 as URLRequest }
            continuing.began(download, operationID: operationID)
            entry = continuing
        } else {
            let request = download.originalRequest.map { $0 as URLRequest }
            let suggested = request?.url?.lastPathComponent
            let name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? "download"
            let made = FetchEntry(name: name, request: request, webView: webView)
            made.download = download
            if listed { entries.append(made) }
            entry = made
        }

        let item = Running(download, entry: entry, owner: owner, helper: helper, listed: listed || continuing != nil)
        running[ObjectIdentifier(download)] = item
        leaving?.cancel()
        leaving = nil
        done = false
        showing = true
        item.watch = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.measure() }
        }
        measure()
        return true
    }

    /// Destination chosen by the browser, or remembered for a resumed attempt.
    func destination(for download: WKDownload) -> URL? {
        running[ObjectIdentifier(download)]?.entry?.destination
    }

    /// Where the file is going, known: its progress is put on it, for the
    /// Finder's bar under the file and the Dock's Downloads stack.
    func going(_ download: WKDownload, to file: URL, cancel: @escaping @Sendable () -> Void) {
        guard let item = running[ObjectIdentifier(download)] else { return }
        if let shown = item.shown, shown.fileURL == file {
            shown.completedUnitCount = download.progress.completedUnitCount
            item.entry?.record(download.progress)
            return
        }
        item.entry?.reached(file)
        let shown = Progress(totalUnitCount: max(1, download.progress.totalUnitCount))
        shown.kind = .file
        shown.fileOperationKind = .downloading
        shown.fileURL = file
        shown.isCancellable = true
        // Finder cancellation can complete without a WKDownload delegate
        // failure callback, so its handler owns the same cleanup path.
        shown.cancellationHandler = cancel
        shown.completedUnitCount = download.progress.completedUnitCount
        shown.publish()
        item.shown = shown
        item.entry?.record(download.progress)
    }

    func entry(for download: WKDownload) -> FetchEntry? {
        running[ObjectIdentifier(download)]?.entry
    }

    func beginStop(_ entry: FetchEntry, action: FetchEntry.StopAction) -> StopOperation? {
        guard entry.state == .downloading, let download = entry.download,
              let item = running[ObjectIdentifier(download)], item.entry === entry else { return nil }
        let token = entry.preparingToStop(action)
        item.stopAction = action
        tellDock()
        item.operationID = token
        return StopOperation(download: download, entry: entry, operationID: token)
    }

    /// The Finder can cancel a private download too, so this overload works
    /// from the active WebKit download rather than requiring a visible row.
    func beginFinderStop(_ download: WKDownload) -> StopOperation? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        if let entry = item.entry {
            if entry.state == .pausing {
                _ = upgradeStopToCancel(entry)
                return nil
            }
            return beginStop(entry, action: .cancel)
        }
        let token = UUID()
        item.stopAction = .cancel
        tellDock()
        item.operationID = token
        return StopOperation(download: download, entry: nil, operationID: token)
    }

    /// Finish a pause or cancellation even when WebKit sends no delegate
    /// callback. The operation token rejects a late completion from an older
    /// attempt after the user has already resumed or retried it.
    func stopped(_ operation: StopOperation, resumeData: Data?) -> Ended? {
        let key = ObjectIdentifier(operation.download)
        guard let item = running[key], item.operationID == operation.operationID,
              let action = item.stopAction else { return nil }
        if let entry = operation.entry {
            guard entry.operationID == operation.operationID,
                  entry.pendingStop == action else { return nil }
            entry.recordTerminal(operation.download.progress)
            if action == .cancel { entry.discardOwnedPartialFile() }
            entry.stopped(action, data: resumeData)
            if action == .cancel { remove(entry) }
        }
        guard let ended = take(operation.download) else { return nil }
        settle(succeeded: false)
        return Ended(owner: ended.owner, announceFailure: false)
    }

    func beginResume(_ entry: FetchEntry) -> StartOperation? {
        guard entry.canResume, let data = entry.resumeData, let store = entry.store else { return nil }
        guard entry.partialFileIsOurs else {
            entry.lostPartialFile()
            return nil
        }
        let (webView, helper) = Self.view(for: entry, store: store)
        let token = entry.preparingToStart()
        return StartOperation(entry: entry, webView: webView, helper: helper, request: entry.request, resumeData: data, operationID: token)
    }

    /// `destination` is asked for once the partial file is let go, so a
    /// retry can have the name back.
    func beginRetry(_ entry: FetchEntry, destination: () -> URL) -> StartOperation? {
        guard entry.canRetry, let request = entry.request, let store = entry.store else { return nil }
        entry.discardOwnedPartialFile()
        let (webView, helper) = Self.view(for: entry, store: store)
        let token = entry.preparingToStart(destination: destination())
        entry.resumeData = nil
        entry.resetProgress()
        return StartOperation(entry: entry, webView: webView, helper: helper, request: request, resumeData: nil, operationID: token)
    }

    /// The page's view while its tab is open; once it has closed, a view of
    /// the attempt's own on the same store, so the same cookies go with it
    /// and no others. It shows no page and runs no extension.
    private static func view(for entry: FetchEntry, store: WKWebsiteDataStore) -> (WKWebView, Bool) {
        if let page = entry.webView, page.configuration.websiteDataStore === store { return (page, false) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.processPool = Web.pool
        configuration.applicationNameForUserAgent = Web.userAgentName
        return (WKWebView(frame: .zero, configuration: configuration), true)
    }

    /// A new WKDownload returned from either WebKit resume API joins the same
    /// row. An obsolete callback is canceled before it can replace newer work.
    func accepts(_ operation: StartOperation) -> Bool {
        operation.entry.state == .resuming && operation.entry.operationID == operation.operationID
    }

    /// Cancel can race the small interval after WebKit accepted resume/retry
    /// but before it returned the new WKDownload. Invalidating this token
    /// makes that callback cancel its download instead of reviving this row.
    func removeStarting(_ entry: FetchEntry) {
        guard entry.state == .resuming else { return }
        entry.discardOwnedPartialFile()
        remove(entry)
    }

    /// Turn an in-flight pause into a discard while keeping the original
    /// cancel completion token, which is the reliable cleanup callback.
    func upgradeStopToCancel(_ entry: FetchEntry) -> Bool {
        guard entry.state == .pausing, let download = entry.download,
              let item = running[ObjectIdentifier(download)], item.entry === entry else { return false }
        entry.pendingStop = .cancel
        item.stopAction = .cancel
        tellDock()
        return true
    }

    /// Arrived. The Dock's Downloads stack is told, as Safari tells it, and
    /// bounces. Successful files move to Loot and no longer remain as entries.
    func finish(_ download: WKDownload, file: URL?) -> Ended? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        if let entry = item.entry { remove(entry) }
        guard let ended = take(download) else { return nil }
        if let file {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: file.path
            )
        }
        settle(succeeded: true)
        return Ended(owner: ended.owner, announceFailure: false)
    }

    /// Failed or canceled. Preserve resume data and the real WebKit error for
    /// visible entries, while intentional pause/cancel callbacks stay quiet.
    func fail(_ download: WKDownload, error: Error, resumeData: Data?) -> Ended? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        // The cancel completion provides authoritative resume data. A
        // delegate failure may arrive first with nil, so keep tracking until
        // that completion decides whether this was a pause or a discard.
        if item.stopAction != nil { return nil }
        if let entry = item.entry {
            entry.recordTerminal(download.progress)
            entry.failed(error, resumeData: resumeData)
            // A private download has no row to resume it from: what it
            // left half-written goes.
            if !item.listed { entry.discardOwnedPartialFile() }
        }
        guard let ended = take(download) else { return nil }
        settle(succeeded: false)
        return Ended(owner: ended.owner, announceFailure: true)
    }

    /// Destination selection canceled, so remove the provisional row and all
    /// active bookkeeping without presenting an error.
    func destinationCancelled(_ download: WKDownload) -> Ended? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        if let entry = item.entry { remove(entry) }
        guard let ended = take(download) else { return nil }
        settle(succeeded: false)
        return Ended(owner: ended.owner, announceFailure: false)
    }

    /// Remove a paused or failed row, discarding its in-memory resume state.
    func removeStopped(_ entry: FetchEntry) {
        guard entry.state == .paused || entry.state == .failed else { return }
        entry.discardOwnedPartialFile()
        remove(entry)
    }

    private func remove(_ entry: FetchEntry) {
        entries.removeAll { $0 === entry }
        entry.clear()
    }

    private func take(_ download: WKDownload) -> Running? {
        guard let item = running.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        item.watch?.invalidate()
        item.shown?.unpublish()
        item.entry?.download = nil
        tellDock()
        return item
    }

    var dockLoads: [DockLoad] {
        running.values.map {
            DockLoad(received: $0.download.progress.completedUnitCount, expected: $0.download.progress.totalUnitCount,
                     underWay: $0.stopAction == nil && !SiteFileAsk.shared.holds($0.download))
        }
    }

    func heldChanged() {
        tellDock()
    }

    private func tellDock() {
        guard self === Shared.fetches else { return }
        DockBar.shared.update(dockLoads)
    }

    /// The last one in: the circle says so, then goes. One that failed with
    /// nothing else running takes the circle away at once. Stopped entries do
    /// not count as activity and cannot leave a spinning ring behind.
    private func settle(succeeded: Bool) {
        guard running.isEmpty else { return measure() }
        guard succeeded else {
            showing = false
            done = false
            fraction = nil
            return
        }
        fraction = 1
        done = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, running.isEmpty else { return }
            showing = false
            done = false
            fraction = nil
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Fetches.linger, execute: work)
    }

    /// The running downloads, together, in whole percents; each file's own
    /// progress and row are brought up to date on the way.
    private func measure() {
        var total: Int64 = 0
        var completed: Int64 = 0
        var sized = true
        for item in running.values {
            let progress = item.download.progress
            if progress.totalUnitCount > 0 {
                total += progress.totalUnitCount
                completed += progress.completedUnitCount
            } else {
                sized = false
            }
            if let shown = item.shown {
                if progress.totalUnitCount > 0, shown.totalUnitCount != progress.totalUnitCount {
                    shown.totalUnitCount = progress.totalUnitCount
                }
                shown.completedUnitCount = progress.completedUnitCount
            }
            item.entry?.record(progress)
        }
        tellDock()
        guard !running.isEmpty else { return }
        let now: Double? = sized && total > 0 ? (Double(completed) / Double(total) * 100).rounded() / 100 : nil
        if now != fraction { fraction = now }
    }
}

extension Fetches {
    func benchState(showing: Bool, fraction: Double?, done: Bool) {
        self.showing = showing
        self.fraction = fraction
        self.done = done
    }

    static let benchStages = ["empty", "running", "kept", "failed", "many"]
    private static var benchKept: [Keep] = []

    func benchStage(_ stage: String, loot: Loot) {
        Self.benchKept.forEach(loot.forget)
        Self.benchKept = []
        entries.filter { $0.download == nil }.forEach(remove)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-bench-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = max(loot.clearedAt, Date())
        func keep(_ name: String, from: String, ago: TimeInterval, missing: Bool = false) {
            let file = folder.appendingPathComponent(name)
            if missing {
                try? FileManager.default.removeItem(at: file)
            } else if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: Data(count: 2048))
            }
            let made = Keep(name: name, from: from, path: file.path, date: base.addingTimeInterval((60 - ago) / 1000))
            Self.benchKept.append(made)
            loot.add(made)
        }
        let long = "Quarterly planning notes and the appendix nobody asked for, final draft (revised) 2026-11-13.pdf"
        var staged: [FetchEntry] = []
        switch stage {
        case "running":
            staged = [.bench("Xcode_27.1.xip", .downloading, done: 1_930_000_000, total: 4_600_000_000)]
        case "kept":
            keep("Invoice 1042.pdf", from: "billing.example.com", ago: 30)
            keep("broadway-press-kit.zip", from: "example.org", ago: 20)
            keep("Screenshot 2026-11-13.png", from: "", ago: 10)
        case "failed":
            staged = [.bench("ubuntu-26.10-desktop-arm64.iso", .failed, done: 310_000_000, total: 6_100_000_000,
                             error: "The network connection was lost.")]
            keep("Invoice 1042.pdf", from: "billing.example.com", ago: 30)
            keep("broadway-press-kit.zip", from: "example.org", ago: 20)
        case "many":
            staged = [
                .bench("Xcode_27.1.xip", .downloading, done: 1_930_000_000, total: 4_600_000_000),
                .bench("stream-capture.mov", .downloading, done: 48_000_000, total: 0),
                .bench(long, .downloading, done: 2_400_000, total: 9_800_000),
                .bench("dataset.tar.gz", .paused, done: 710_000_000, total: 1_200_000_000),
                .bench("ubuntu-26.10-desktop-arm64.iso", .failed, done: 310_000_000, total: 6_100_000_000,
                       error: "The network connection was lost."),
            ]
            keep("Notes.txt", from: "example.com", ago: 60)
            keep("Installer.dmg", from: "downloads.example.com", ago: 50)
            keep("Gone already.pdf", from: "example.com", ago: 40, missing: true)
            keep(long, from: "a-rather-long-subdomain.of.a.long-host-name.example.com", ago: 30)
            keep("broadway-press-kit.zip", from: "example.org", ago: 20)
            keep("Screenshot 2026-11-13.png", from: "", ago: 10)
        default:
            break
        }
        entries.append(contentsOf: staged)
        let active = entries.filter { $0.state == .downloading }
        let sized = active.allSatisfy { $0.totalBytes > 0 }
        benchState(showing: !active.isEmpty, fraction: sized ? active.first?.fraction : nil, done: false)
    }
}

extension FetchEntry {
    static func bench(_ name: String, _ state: State, done: Int64, total: Int64, error: String? = nil) -> FetchEntry {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9/")!.appendingPathComponent(name))
        request.httpMethod = "GET"
        let made = FetchEntry(name: name, request: request, webView: nil)
        made.store = .nonPersistent()
        made.state = state
        made.completedBytes = done
        made.totalBytes = total
        made.fraction = total > 0 ? min(1, Double(done) / Double(total)) : nil
        made.errorDescription = error
        if state == .paused { made.resumeData = Data([0]) }
        return made
    }
}

final class FetchDoorView: KitButton {
    let browser: Browser
    let fetches: Fetches
    var always = false { didSet { if always != oldValue { needsLayout = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsLayout = true } } }
    var side: CGFloat = 26 { didSet { if side != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }
    var glyph: CGFloat = 14 { didSet { if glyph != oldValue { restyle() } } }

    private let ground = KitBox(fill: nil, corners: .radius(8))
    private let stage = NSView()
    private let rest = KitSymbol("arrow.down.circle", style: KitSymbol.Style(size: 14), tint: KitColor.muted)
    private let done = KitSymbol("arrow.down", style: KitSymbol.Style(size: 10, weight: .semibold), tint: KitColor.ink)
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let ring = RingView()
    private var face: Face?
    private var kicked = false
    private var pressedAt: TimeInterval?

    private enum Face: Equatable { case rest, done, fraction, turning }

    static func shows(_ fetches: Fetches, _ prefs: Preferences) -> Bool {
        fetches.showing || fetches.waiting || !fetches.entries.isEmpty || prefs.alwaysShowsDownloads
    }

    init(browser: Browser, fetches: Fetches, always: Bool = false) {
        self.browser = browser
        self.fetches = fetches
        self.always = always
        super.init(.plain(press: 0.9), label: "Downloads")
        addSubview(ground, positioned: .below, relativeTo: nil)
        stage.wantsLayer = true
        content = stage
        for view in [rest, done, ring] as [NSView] { stage.addSubview(view) }
        for shape in [track, fill] {
            shape.fillColor = nil
            shape.lineWidth = 1.5
            shape.lineCap = .round
            stage.layer?.addSublayer(shape)
        }
        kitAccess(label: "Downloads", help: "Downloads")
        action = { [weak self] in
            guard let self else { return }
            let shut = self.browser.downloadsShutBy
            self.browser.downloadsShutBy = nil
            if let shut, shut == self.pressedAt {
                if self.browser.downloadsOpen { self.browser.downloadsOpen = false }
                return
            }
            self.browser.downloadsDoor = self.doorFrame
            self.browser.downloadsAnchor = self
            self.browser.downloadsOpen.toggle()
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.timestamp
        super.mouseDown(with: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    private func restyle() {
        rest.style = KitSymbol.Style(size: glyph)
        done.style = KitSymbol.Style(size: (glyph * 10 / 14).rounded(), weight: .semibold)
        needsLayout = true
    }

    var doorFrame: CGRect {
        guard let root = window?.contentView else { return .zero }
        let rect = convert(bounds, to: root)
        return root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    override func hoverChanged() {
        super.hoverChanged()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        isHidden = !(always || Self.shows(fetches, browser.prefs))
        super.layout()
        ground.frame = bounds
        let across = glyph - 2
        let box = NSRect(x: (bounds.width - across) / 2, y: (bounds.height - across) / 2, width: across, height: across)
        stage.frame = kitSnap(box)
        let inner = stage.bounds
        rest.centreInk(in: inner)
        done.centreInk(in: inner)
        ring.frame = inner
        let dark = kitDark
        ground.fill = hovering ? Palette.NS.hover : nil
        rest.ink = ink
        done.ink = ink
        rest.tint = hovering ? KitColor.ink : KitColor.muted
        rest.opacity = hovering ? 0.7 : 1
        done.opacity = 0.75
        let path = CGPath(ellipseIn: inner, transform: nil)
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: inner.midX, y: inner.midY), radius: inner.width / 2,
                   startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = inner
        fill.frame = inner
        track.path = path
        fill.path = arc
        track.strokeColor = ink.color(KitColor.muted, .quiet, opacity: 0.3, dark: dark).cgColor
        fill.strokeColor = ink.color(KitColor.ink, .ink, opacity: 0.7, dark: dark).cgColor
        CATransaction.commit()
        let now: Face = !fetches.showing ? .rest : fetches.done ? .done : fetches.fraction != nil ? .fraction : .turning
        if now != face {
            if face != nil, window != nil { stage.layer?.kitTransition(Motion.kitQuick) }
            face = now
        }
        rest.isHidden = now != .rest
        done.isHidden = now != .done
        ring.isHidden = now != .turning
        track.isHidden = now != .fraction
        fill.isHidden = now != .fraction
        if let fraction = fetches.fraction {
            let end = max(0.02, fraction)
            if fill.strokeEnd != end {
                fill.kitAnimate("strokeEnd", to: end, curve: Motion.reduced ? .none : .easeOut(0.2))
            }
        }
        if fetches.done != kicked {
            kicked = fetches.done
            if kicked, !Motion.reduced, window != nil { kick() }
        }
        if browser.downloadsOpen || window != nil {
            if browser.downloadsAnchor?.window == nil, window != nil, !isHidden { browser.downloadsAnchor = self }
            let frame = doorFrame
            if browser.downloadsAnchor === self, frame != .zero, browser.downloadsDoor != frame, browser.downloadsOpen {
                browser.downloadsDoor = frame
            }
        }
    }

    private func kick() {
        guard let layer = stage.layer else { return }
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        lift.values = [0, isFlipped ? -2.5 : 2.5, 0]
        lift.keyTimes = [0, 0.3, 1]
        lift.duration = 0.23
        lift.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        layer.add(lift, forKey: "kick")
    }
}
