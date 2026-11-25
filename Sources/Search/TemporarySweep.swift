import BroadwayCLI
import Foundation

enum TemporarySweep {
    static func atLaunch() {
        guard !Store.unitTests else { return }
        DispatchQueue.global(qos: .utility).async { TempSweep.sweep() }
    }
}
