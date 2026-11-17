import Darwin
import Foundation
import os

enum MemoryCeiling {
    static let lowest: UInt64 = 8 << 30
    static let highest: UInt64 = 24 << 30
    static let every: TimeInterval = 5

    static func limit(physical: UInt64) -> UInt64 {
        min(highest, max(lowest, physical / 2))
    }
}

enum MemoryWords {
    static let title = "This page used too much memory and was stopped"
    static let line = "It was stopped so your Mac could keep going. Trying again may do the same."
    static let agent = "The page used too much memory and was stopped. Loading it again may do the same."
}

struct MemoryEnd: Equatable, Sendable {
    let pid: Int32
    var tabs: [UUID]
    let bytes: UInt64
    let ceiling: UInt64
}

struct MemorySample: Equatable, Sendable {
    let bytes: UInt64
    let started: UInt64
}

struct MemoryReading: Sendable {
    let pid: Int32
    let tabs: [UUID]
    let bytes: UInt64
}

final class MemoryWatch: @unchecked Sendable {
    static let shared = MemoryWatch(physical: ProcessInfo.processInfo.physicalMemory)

    let physical: UInt64
    var renew: (@Sendable () -> Void)?

    private let lock = NSLock()
    private let read: @Sendable (Int32) -> MemorySample?
    private let isPage: @Sendable (Int32) -> Bool
    private let end: @Sendable (Int32) -> Bool
    private let queue = DispatchQueue(label: "com.ysmaliak.broadway.memory", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pages: [Int32: [UUID]] = [:]
    private var ended: [Int32: MemoryEnd] = [:]
    private var gone: Set<Int32> = []
    private var starts: [Int32: UInt64] = [:]
    private var lowered: UInt64?
    private var last: [MemoryReading] = []
    private var count = 0
    private var renewals = 0

    init(physical: UInt64,
         read: @escaping @Sendable (Int32) -> MemorySample? = MemoryWatch.sample,
         isPage: @escaping @Sendable (Int32) -> Bool = MemoryWatch.isPageProcess,
         end: @escaping @Sendable (Int32) -> Bool = { kill($0, SIGKILL) == 0 }) {
        self.physical = physical
        self.read = read
        self.isPage = isPage
        self.end = end
    }

    var ceiling: UInt64 {
        locked { lowered ?? MemoryCeiling.limit(physical: physical) }
    }

    var readings: Int { locked { count } }
    var renewed: Int { locked { renewals } }
    var lastReadings: [MemoryReading] { locked { last } }
    var watched: [Int32: [UUID]] { locked { pages } }
    var waiting: [MemoryEnd] { locked { Array(ended.values) } }

    func lower(to bytes: UInt64?) {
        locked { lowered = bytes }
    }

    func start() {
        locked {
            guard timer == nil else { return }
            let made = DispatchSource.makeTimerSource(queue: queue)
            made.schedule(deadline: .now() + MemoryCeiling.every, repeating: MemoryCeiling.every, leeway: .milliseconds(500))
            made.setEventHandler { [weak self] in self?.tick() }
            made.resume()
            timer = made
        }
        renew?()
    }

    func pages(_ list: [Int32: [UUID]]) {
        locked {
            pages = list
            renewals += 1
            gone = gone.filter { list[$0] != nil }
            starts = starts.filter { list[$0.key] != nil }
            for (pid, record) in ended {
                let moved = Set(list.filter { $0.key != pid }.values.joined())
                let left = record.tabs.filter { !moved.contains($0) }
                if left.isEmpty { ended[pid] = nil } else { ended[pid]?.tabs = left }
            }
        }
    }

    func tick() {
        let (list, limit) = locked { (pages, lowered ?? MemoryCeiling.limit(physical: physical)) }
        var seen: [MemoryReading] = []
        for (pid, tabs) in list.sorted(by: { $0.key < $1.key }) {
            guard !locked({ gone.contains(pid) }), let sample = read(pid) else { continue }
            let known = locked { starts[pid] }
            guard known == nil || known == sample.started else { continue }
            if known == nil { locked { starts[pid] = sample.started } }
            let bytes = sample.bytes
            seen.append(MemoryReading(pid: pid, tabs: tabs, bytes: bytes))
            guard bytes > limit, isPage(pid) else { continue }
            let record = MemoryEnd(pid: pid, tabs: tabs, bytes: bytes, ceiling: limit)
            locked {
                ended[pid] = record
                gone.insert(pid)
            }
            if end(pid) {
                MemoryWatch.log.notice("A page process was ended at \(bytes >> 20, privacy: .public) MB, over the ceiling of \(limit >> 20, privacy: .public) MB. Tabs in it: \(tabs.count, privacy: .public)")
            } else {
                locked {
                    ended[pid] = nil
                    gone.remove(pid)
                }
            }
        }
        locked {
            last = seen
            count += 1
        }
        renew?()
    }

    func holds(_ tab: UUID) -> Bool {
        locked { ended.values.contains { $0.tabs.contains(tab) } }
    }

    func take(_ tab: UUID) -> MemoryEnd? {
        locked {
            guard let found = ended.first(where: { $0.value.tabs.contains(tab) }) else { return nil }
            var record = found.value
            record.tabs.removeAll { $0 == tab }
            ended[found.key] = record.tabs.isEmpty ? nil : record
            return found.value
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    private static let log = Logger(subsystem: "com.ysmaliak.broadway", category: "Memory")

    static func sample(_ pid: Int32) -> MemorySample? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? MemorySample(bytes: info.ri_phys_footprint, started: info.ri_proc_start_abstime) : nil
    }

    static func isPageProcess(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return path.contains("com.apple.WebKit.WebContent")
    }
}
