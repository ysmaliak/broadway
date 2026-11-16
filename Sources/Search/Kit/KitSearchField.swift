import AppKit

final class KitSearchField: NSSearchField, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var takesFocus = false

    init(prompt: String, text: String = "", takesFocus: Bool = false) {
        self.takesFocus = takesFocus
        super.init(frame: .zero)
        placeholderString = prompt
        stringValue = text
        sendsSearchStringImmediately = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel(prompt)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard takesFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
    }

    func controlTextDidChange(_ note: Notification) {
        onChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let onSubmit else { return false }
        onSubmit()
        return true
    }
}
