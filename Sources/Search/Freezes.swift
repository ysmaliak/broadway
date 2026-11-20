import AppKit
import Darwin
import MachO
import MetricKit

struct Freeze: Codable, Equatable {
    enum Front: String, Codable {
        case page, internalPage, none
    }

    var at: Date
    var seconds: Double
    var ended: Bool
    var version: String
    var build: String
    var system: String
    var model: String
    var front: Front
    var stack: [String] = []
    var images: [String] = []
    var stackFrom: String? = nil
}

struct FreezeFacts: Sendable {
    var version: String
    var build: String
    var system: String
    var model: String

    @MainActor static var here: FreezeFacts {
        let info = Bundle.main.infoDictionary
        return FreezeFacts(version: info?["CFBundleShortVersionString"] as? String ?? "dev", build: info?["CFBundleVersion"] as? String ?? "dev",
                           system: Support.system, model: Support.model)
    }

    func freeze(at: Date, seconds: Double, ended: Bool, front: Freeze.Front) -> Freeze {
        Freeze(at: at, seconds: seconds, ended: ended, version: version, build: build, system: system, model: model, front: front)
    }
}

final class FreezeBook: @unchecked Sendable {
    static let room = 20
    static let threshold: TimeInterval = 2
    static let shared = FreezeBook(file: Store.file("freezes.json"))

    let file: URL
    let threshold: TimeInterval
    private let lock = NSLock()
    private var kept: [Freeze] = []
    private let queue = DispatchQueue(label: "broadway.freezes", qos: .utility)

    init(file: URL, threshold: TimeInterval = FreezeBook.threshold) {
        self.file = file
        self.threshold = threshold
        if let data = try? Data(contentsOf: file), let list = try? Self.decoder.decode([Freeze].self, from: data) {
            kept = Array(list.suffix(Self.room))
        }
    }

    private static let decoder: JSONDecoder = {
        let made = JSONDecoder()
        made.dateDecodingStrategy = .iso8601
        return made
    }()

    private static let encoder: JSONEncoder = {
        let made = JSONEncoder()
        made.dateEncodingStrategy = .iso8601
        made.outputFormatting = [.prettyPrinted, .sortedKeys]
        return made
    }()

    var all: [Freeze] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    var latest: Freeze? { all.last }

    func counts(_ seconds: Double) -> Bool { seconds >= threshold }

    @discardableResult
    func note(_ freeze: Freeze) -> Bool {
        guard counts(freeze.seconds) else { return false }
        change { list in
            if let at = list.lastIndex(where: { $0.at == freeze.at }) {
                var merged = freeze
                if merged.stack.isEmpty {
                    merged.stack = list[at].stack
                    merged.images = list[at].images
                    merged.stackFrom = list[at].stackFrom
                }
                list[at] = merged
            } else {
                list.append(freeze)
            }
        }
        return true
    }

    func attach(stack: [String], images: [String] = [], from source: String, seconds: Double, between start: Date, and end: Date) {
        change { list in
            let open = list.indices.filter { list[$0].stack.isEmpty && list[$0].at >= start.addingTimeInterval(-60) && list[$0].at <= end }
            guard let best = open.min(by: { abs(list[$0].seconds - seconds) < abs(list[$1].seconds - seconds) }) else { return }
            list[best].stack = stack
            list[best].images = images
            list[best].stackFrom = source
        }
    }

    func forgetAll() {
        change { $0.removeAll() }
    }

    func settle() { queue.sync {} }

    private func change(_ edit: (inout [Freeze]) -> Void) {
        lock.lock()
        edit(&kept)
        if kept.count > Self.room { kept.removeFirst(kept.count - Self.room) }
        let snapshot = kept
        lock.unlock()
        let file = file
        queue.async {
            guard let data = try? Self.encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

final class FreezeWatch: @unchecked Sendable {
    private struct Ping {
        var sent: UInt64
        var at: Date
        var caught = false
    }

    let book: FreezeBook
    let tick: TimeInterval
    private let facts: FreezeFacts
    private let front: @MainActor () -> Freeze.Front
    private let lock = NSLock()
    private var ping: Ping?
    private var lastFront: Freeze.Front = .none
    private var timer: DispatchSourceTimer?
    private var main: thread_act_t = 0
    private let queue = DispatchQueue(label: "broadway.freeze-watch", qos: .userInitiated)

    @MainActor
    init(book: FreezeBook, tick: TimeInterval = 0.5, facts: FreezeFacts? = nil, front: @escaping @MainActor () -> Freeze.Front) {
        self.book = book
        self.tick = tick
        self.facts = facts ?? .here
        self.front = front
    }

    static func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    @MainActor
    func start() {
        guard timer == nil else { return }
        main = pthread_mach_thread_np(pthread_self())
        lastFront = front()
        let made = DispatchSource.makeTimerSource(queue: queue)
        made.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(Int(tick * 500)))
        made.setEventHandler { [weak self] in self?.beat() }
        timer = made
        made.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func beat() {
        let now = Self.uptime()
        lock.lock()
        var send: UInt64?
        var caught: (Ping, Double, Freeze.Front)?
        if var waiting = ping {
            let age = Double(now - waiting.sent) / 1e9
            if !waiting.caught, book.counts(age) {
                waiting.caught = true
                ping = waiting
                caught = (waiting, age, lastFront)
            }
        } else {
            ping = Ping(sent: now, at: Date())
            send = now
        }
        lock.unlock()
        if let send {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.answered(send) }
            }
        }
        if let (waiting, age, front) = caught {
            let found = FreezeStack.sample(main)
            var freeze = facts.freeze(at: waiting.at, seconds: age, ended: false, front: front)
            let said = FreezeStack.describe(found)
            freeze.stack = said.frames
            freeze.images = said.images
            freeze.stackFrom = said.frames.isEmpty ? nil : "watchdog"
            book.note(freeze)
        }
    }

    @MainActor
    private func answered(_ sent: UInt64) {
        let now = Self.uptime()
        let shown = front()
        lock.lock()
        let waiting = ping
        let before = lastFront
        if ping?.sent == sent { ping = nil }
        lastFront = shown
        lock.unlock()
        guard let waiting, waiting.sent == sent else { return }
        let lasted = Double(now - sent) / 1e9
        guard book.counts(lasted) else { return }
        book.note(facts.freeze(at: waiting.at, seconds: lasted, ended: true, front: before))
    }
}

enum FreezeStack {
    static let depth = 96

    static func sample(_ thread: thread_act_t) -> [UInt] {
        guard thread != 0, thread != pthread_mach_thread_np(pthread_self()) else { return [] }
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: depth)
        defer { buffer.deallocate() }
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let count = walk(thread, into: buffer)
        thread_resume(thread)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    private static func walk(_ thread: thread_act_t, into buffer: UnsafeMutablePointer<UInt>) -> Int {
        var pc: UInt = 0
        var fp: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &size) }
        }
        guard got == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc)
        fp = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var size = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { thread_get_state(thread, x86_THREAD_STATE64, $0, &size) }
        }
        guard got == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip)
        fp = UInt(state.__rbp)
        #endif
        var count = 0
        if pc != 0 {
            buffer[0] = strip(pc)
            count = 1
        }
        var frame: (UInt, UInt) = (0, 0)
        while fp != 0, fp % 8 == 0, count < depth {
            var read: vm_size_t = 0
            let done = withUnsafeMutablePointer(to: &frame) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                  vm_address_t(UInt(bitPattern: $0)), &read)
            }
            guard done == KERN_SUCCESS, read == vm_size_t(MemoryLayout<(UInt, UInt)>.size) else { break }
            let back = strip(frame.1)
            guard back != 0 else { break }
            buffer[count] = back
            count += 1
            guard frame.0 > fp else { break }
            fp = frame.0
        }
        return count
    }

    static func describe(_ addresses: [UInt]) -> (frames: [String], images: [String]) {
        var frames: [String] = []
        var images: [UInt: String] = [:]
        let mainBase = mainImageBase()
        for (index, address) in addresses.enumerated() {
            var info = Dl_info()
            let number = String(index).padding(toLength: 4, withPad: " ", startingAt: 0)
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = UnsafeRawPointer(info.dli_fbase) else {
                frames.append(number + "???".padding(toLength: 28, withPad: " ", startingAt: 0) + " " + hex(address))
                continue
            }
            let baseAddress = UInt(bitPattern: base)
            let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "???"
            if images[baseAddress] == nil { images[baseAddress] = imageLine(base, name: image) }
            var said = "\(image) + \(hex(address - baseAddress))"
            if baseAddress != mainBase, let symbol = info.dli_sname, let start = info.dli_saddr {
                said = demangled(String(cString: symbol)) + " + \(address - UInt(bitPattern: start))"
            }
            frames.append(number + image.padding(toLength: max(28, image.count), withPad: " ", startingAt: 0) + " " + said)
        }
        return (frames, images.sorted { $0.key < $1.key }.map(\.value))
    }

    private static func hex(_ value: UInt) -> String { "0x" + String(value, radix: 16) }

    private static func mainImageBase() -> UInt {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.filetype == UInt32(MH_EXECUTE) else { continue }
            return UInt(bitPattern: header)
        }
        return 0
    }

    private static func imageLine(_ base: UnsafeRawPointer, name: String) -> String {
        "\(hex(UInt(bitPattern: base))) \(name) \(uuid(of: base) ?? "")"
    }

    private static func uuid(of base: UnsafeRawPointer) -> String? {
        let header = base.assumingMemoryBound(to: mach_header_64.self).pointee
        guard header.magic == MH_MAGIC_64 else { return nil }
        var command = base.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                let found = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: found).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32)
        -> UnsafeMutablePointer<CChar>?

    private static let demangler: Demangle? = {
        guard let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(found, to: Demangle.self)
    }()

    static func demangled(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s"), let demangler else { return symbol }
        return symbol.withCString { name in
            guard let out = demangler(name, strlen(name), nil, nil, 0) else { return symbol }
            defer { free(out) }
            return String(cString: out)
        }
    }

    static func frames(fromMetricTree data: Data) -> [String] {
        guard var tree = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if let inner = tree["callStackTree"] as? [String: Any] { tree = inner }
        guard let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        var frames: [String] = []
        while let here = frame, frames.count < depth {
            let image = URL(fileURLWithPath: here["binaryName"] as? String ?? "???").lastPathComponent
            let offset = (here["offsetIntoBinaryTextSegment"] as? NSNumber)?.uintValue ?? 0
            let number = String(frames.count).padding(toLength: 4, withPad: " ", startingAt: 0)
            frames.append(number + image.padding(toLength: max(28, image.count), withPad: " ", startingAt: 0) + " \(image) + \(hex(offset))")
            frame = (here["subFrames"] as? [[String: Any]])?.first
        }
        return frames
    }
}

enum FreezeReport {
    static func text(_ freeze: Freeze, timeZone: TimeZone = .current) -> String {
        let seconds = String(format: "%.1f", freeze.seconds)
        let headline = freeze.ended
            ? "Broadway stopped answering for \(seconds) seconds"
            : "Broadway stopped answering for \(seconds) seconds or more and did not answer again before it quit"
        let when = ISO8601DateFormatter.string(from: freeze.at, timeZone: timeZone, formatOptions: [.withInternetDateTime])
        let front: String
        switch freeze.front {
        case .page: front = "a page"
        case .internalPage: front = "a Broadway page"
        case .none: front = "no tab"
        }
        var lines = [
            headline,
            "",
            "When: \(when)",
            "Broadway: \(freeze.version) (\(freeze.build))",
            "System: \(freeze.system)",
            "Mac: \(freeze.model)",
            "In front: \(front)",
            "",
        ]
        if freeze.stack.isEmpty {
            lines.append("Main thread: not caught")
        } else {
            lines.append(freeze.stackFrom == "MetricKit" ? "Main thread, from MetricKit:" : "Main thread:")
            lines.append("```")
            lines += freeze.stack
            if !freeze.images.isEmpty {
                lines.append("")
                lines.append("Images:")
                lines += freeze.images
            }
            lines.append("```")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

final class FreezeMetrics: NSObject, MXMetricManagerSubscriber {
    let book: FreezeBook

    init(book: FreezeBook) {
        self.book = book
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                let frames = FreezeStack.frames(fromMetricTree: hang.callStackTree.jsonRepresentation())
                guard !frames.isEmpty else { continue }
                book.attach(stack: frames, from: "MetricKit", seconds: seconds, between: payload.timeStampBegin, and: payload.timeStampEnd)
            }
        }
    }
}

@MainActor
enum Freezes {
    private static var watch: FreezeWatch?
    private static var metrics: FreezeMetrics?

    static func front() -> Freeze.Front {
        guard let tab = Front.shared.browser?.active else { return .none }
        if tab.isWeb { return .page }
        return tab.page != nil ? .internalPage : .none
    }

    static func start(book: FreezeBook = .shared) {
        guard watch == nil else { return }
        let made = FreezeWatch(book: book, front: front)
        made.start()
        watch = made
        let listening = FreezeMetrics(book: book)
        MXMetricManager.shared.add(listening)
        metrics = listening
    }

    static var canCopy: Bool { FreezeBook.shared.latest != nil }

    @discardableResult
    static func copyLast(book: FreezeBook = .shared, hands: Support.Hands = .mac, announce: (String) -> Void) -> Bool {
        guard let freeze = book.latest else { return false }
        hands.copy(FreezeReport.text(freeze))
        announce("Freeze report copied")
        return true
    }
}

@MainActor
final class FreezeMenuWatch: NSObject, NSMenuDelegate {
    static let shared = FreezeMenuWatch()
    weak var item: MenuCommand?
    var book: FreezeBook = .shared

    func menuNeedsUpdate(_ menu: NSMenu) {
        item?.allowed = book.latest != nil
    }
}
