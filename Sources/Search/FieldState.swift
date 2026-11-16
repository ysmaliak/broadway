import AppKit
import Observation

@MainActor
@Observable
final class FieldState {
    var editing = false
    var launching = false
    var siteOffer: SearchSite?
    var siteChip: SearchSite?
    var fieldPlace: FieldPlace?
    var placeOffer: FieldPlace?
    var typed = ""
    var offers: [Suggestion] = []
    var fieldSections: [FieldSection] = []
    var ending: String?
    var picked: Int?
    var pointed: Int?
    var refusals = 0
    var focusRequest = 0
    var summoning = false
}

@MainActor
enum FieldLayout {
    static var frames: [String: CGRect] = [:]
    static var changed: [String: CFTimeInterval] = [:]

    static func note(_ id: String, _ frame: CGRect) {
        guard frames[id] != frame else { return }
        frames[id] = frame
        changed[id] = CACurrentMediaTime()
    }

    static func afterCommit(_ done: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { done() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
