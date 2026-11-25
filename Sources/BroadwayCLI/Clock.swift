import Darwin
import Foundation

enum Clock {
    nonisolated(unsafe) static var on = false
    nonisolated(unsafe) static var marks: [[Any]] = []
    nonisolated(unsafe) static var app: Any?

    static func now() -> Double {
        var time = timeval()
        gettimeofday(&time, nil)
        return Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
    }

    static func mark(_ name: String) {
        guard on else { return }
        marks.append([name, now()])
    }

    static func start() {
        guard let value = getenv("BROADWAY_TIMING"), value.pointee != 0, String(cString: value) != "0" else { return }
        on = true
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&name, 4, &info, &size, nil, 0) == 0 {
            let began = info.kp_proc.p_un.__p_starttime
            marks.append(["process", Double(began.tv_sec) * 1000 + Double(began.tv_usec) / 1000])
        }
        mark("main")
    }

    static func heard(_ reply: [String: Any]) {
        guard on, let timing = reply["timing"] else { return }
        app = timing
    }

    static func report() {
        guard on else { return }
        mark("exit")
        var object: [String: Any] = ["cli": marks]
        if let app { object["app"] = app }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardError.write(Data("broadway timing ".utf8) + data + Data([0x0A]))
    }
}
