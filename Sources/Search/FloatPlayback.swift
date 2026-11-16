import AppKit
import Foundation

struct FloatRate: Equatable {
    static let steps: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private(set) var value: Double = 1
    private(set) var available = false
    private var pickedAt: TimeInterval?
    private(set) var request = 0
    private var pending: Int?
    private var reads = 0
    private var accepted = 0

    struct Read: Equatable {
        fileprivate let request: Int
        fileprivate let sequence: Int
    }

    mutating func read() -> Read {
        reads += 1
        return Read(request: request, sequence: reads)
    }

    mutating func received(_ rate: Double?, read: Read, at now: TimeInterval) {
        guard pending == nil, read.request == request, read.sequence > accepted else { return }
        accepted = read.sequence
        polled(rate, at: now)
    }

    mutating func acknowledged(_ rate: Double?, request: Int, at now: TimeInterval) -> Bool {
        guard pending == request else { return false }
        pending = nil
        self.request += 1
        pickedAt = nil
        polled(rate, at: now)
        return true
    }

    static func normalized(_ rate: Double) -> Double {
        abs(rate - 1.0001) < 0.00001 ? 1 : rate
    }

    mutating func polled(_ rate: Double?, at now: TimeInterval) {
        guard let rate, rate.isFinite, rate > 0 else {
            available = false
            pickedAt = nil
            return
        }
        available = true
        if let pickedAt, now - pickedAt < FloatPlay.trust { return }
        pickedAt = nil
        value = Self.normalized(rate)
    }

    mutating func pick(_ rate: Double, at now: TimeInterval) -> Bool {
        guard available, Self.steps.contains(rate) || Tempo.allows(rate) else { return false }
        value = rate
        pickedAt = now
        request += 1
        pending = request
        return true
    }

    func step(_ direction: Int, wrapping: Bool = false) -> Double {
        if direction > 0 {
            return Self.steps.first { $0 > value + 0.001 } ?? (wrapping ? Self.steps[0] : max(value, Self.steps.last!))
        }
        return Self.steps.last { $0 < value - 0.001 } ?? Self.steps[0]
    }

    static func label(_ rate: Double) -> String {
        "\(normalized(rate).formatted(.number.precision(.fractionLength(1...2))))×"
    }
}

enum FloatCommand: Equatable {
    case toggle, seek(Double), speed(Int), tempo(Int), mute, captions, back

    static func read(code: UInt16, flags: NSEvent.ModifierFlags, repeated: Bool = false, tempo: Bool = false) -> Self? {
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let shift = flags.contains(.shift)
        switch code {
        case 49: return shift || repeated ? nil : .toggle
        case 123: return .seek(shift ? -5 : -15)
        case 124: return .seek(shift ? 5 : 15)
        case 1 where tempo: return .tempo(-1)
        case 2 where tempo: return repeated ? nil : .tempo(0)
        case 3 where tempo: return .tempo(1)
        case 43 where shift: return .speed(-1)
        case 47 where shift: return .speed(1)
        case 8: return shift || repeated ? nil : .captions
        case 46: return shift || repeated ? nil : .mute
        case 36, 53: return shift || repeated ? nil : .back
        default: return nil
        }
    }
}
