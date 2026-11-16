import AppKit
import ObjectiveC

final class KitTarget: NSObject {
    let run: (NSControl) -> Void
    init(_ run: @escaping (NSControl) -> Void) { self.run = run }
    @objc func fire(_ sender: NSControl) { run(sender) }
}

private var kitTargetKey: UInt8 = 0

extension NSControl {
    func kitOnChange(_ run: @escaping (NSControl) -> Void) {
        let made = KitTarget(run)
        objc_setAssociatedObject(self, &kitTargetKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        target = made
        action = #selector(KitTarget.fire(_:))
    }
}

enum KitControls {
    static func toggle(id: String, label: String, isOn: Bool, small: Bool = true, system: Bool = false,
                       set: @escaping (Bool) -> Void) -> KitSwitch {
        let made = KitSwitch(isOn: isOn, small: small, label: label, system: system)
        made.onChange = set
        made.kitAccess(id: id, label: label)
        return made
    }

    static func slider(id: String, label: String, value: Double, range: ClosedRange<Double>, ticks: Int = 0,
                       set: @escaping (Double) -> Void) -> NSSlider {
        let made = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        made.numberOfTickMarks = ticks
        made.allowsTickMarkValuesOnly = ticks > 0
        made.isContinuous = true
        made.kitOnChange { set($0.doubleValue) }
        made.kitAccess(id: id, label: label)
        return made
    }

    static func popUp(id: String, label: String, titles: [String], picked: Int,
                      set: @escaping (Int) -> Void) -> NSPopUpButton {
        let made = NSPopUpButton(frame: .zero, pullsDown: false)
        made.addItems(withTitles: titles)
        made.selectItem(at: picked)
        made.kitOnChange { set(($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        made.kitAccess(id: id, label: label)
        return made
    }

    static func field(id: String, label: String, text: String, placeholder: String = "", secure: Bool = false,
                      set: @escaping (String) -> Void) -> NSTextField {
        let made: NSTextField = secure ? NSSecureTextField(string: text) : NSTextField(string: text)
        made.placeholderString = placeholder
        made.bezelStyle = .roundedBezel
        made.lineBreakMode = .byTruncatingTail
        made.usesSingleLineMode = true
        made.kitOnChange { set($0.stringValue) }
        made.kitAccess(id: id, label: label)
        return made
    }
}
