import AppKit

// v30, 25.11.2026: the SYNC overlay (docs/AVSYNC_PLAN.md §3). Marko: "It must be exactly in the same frame, the sound ...
// I can use any microphone." A see-through box under the bar: the chosen sound input's delay against the camera's own
// sound, keys of 1 ms and 10 ms, RESET (back to the measured value), and every stored value. Escape or CLOSE closes.
// AUTO MEASURE is not here yet (v31): tools/avsync.py measures, the app reads the result.
final class SyncPanel: NSView {
    struct Row { let title: String; let value: String; let current: Bool }
    struct Model {
        var sound: String            // "RØDE NT1 5th Gen (A)" or "No sound"
        var value: String            // "+72.5 ms"
        var detail: String           // what the value means / where it came from
        var adjustable: Bool         // false for the reference and for no sound
        var rows: [Row]
        var footer: String
    }
    var onStep: ((Double) -> Void)?
    var onReset: (() -> Void)?
    var onClose: (() -> Void)?

    private let head = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private var steps: [NSButton] = []
    private let reset = NSButton()
    private let closeKey = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 10
        isHidden = true
        setAccessibilityIdentifier("sync-overlay")

        head.font = .systemFont(ofSize: 11, weight: .semibold)
        head.textColor = NSColor.white.withAlphaComponent(0.65)
        head.lineBreakMode = .byTruncatingMiddle
        value.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        value.textColor = .white
        value.setAccessibilityIdentifier("sync-value")
        for l in [detail, footer] {
            l.font = .systemFont(ofSize: 11, weight: .regular)
            l.textColor = NSColor.white.withAlphaComponent(0.75)
        }
        var keys: [NSView] = []
        for (t, d) in [("-10", -10.0), ("-1", -1.0), ("+1", 1.0), ("+10", 10.0)] {
            let b = Self.key(t, self, #selector(stepped(_:)))
            b.tag = Int(d)
            steps.append(b); keys.append(b)
        }
        Self.style(reset, "RESET", self, #selector(resetTapped))
        reset.toolTip = "Back to the measured value (tools/avsync.py, avsync.json)"
        keys.append(reset)
        let row = NSStackView(views: keys)
        row.orientation = .horizontal; row.spacing = 6
        Self.style(closeKey, "CLOSE", self, #selector(closeTapped))
        closeKey.toolTip = "Close (Escape)"
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 3
        let top = NSStackView(views: [head, NSView(), closeKey])
        top.orientation = .horizontal
        let stack = NSStackView(views: [top, value, detail, row, Self.heading("STORED VALUES"), list, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setCustomSpacing(2, after: value)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func heading(_ t: String) -> NSTextField {
        let h = NSTextField(labelWithString: t)
        h.font = .systemFont(ofSize: 11, weight: .semibold)
        h.textColor = NSColor.white.withAlphaComponent(0.6)
        return h
    }
    private static func key(_ t: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(); style(b, t, target, action); return b
    }
    /// the same look as the bar's keys: bold letters, no border, a soft blob behind
    private static func style(_ b: NSButton, _ t: String, _ target: AnyObject, _ action: Selector) {
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        b.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
        b.setAccessibilityTitle(t)
        b.target = target; b.action = action
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    func update(_ m: Model) {
        head.stringValue = "SYNC · " + m.sound
        value.stringValue = m.value
        value.setAccessibilityValue(m.value)
        detail.stringValue = m.detail
        footer.stringValue = m.footer
        footer.isHidden = m.footer.isEmpty
        for b in steps + [reset] { b.isEnabled = m.adjustable; b.alphaValue = m.adjustable ? 1 : 0.4 }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in m.rows {
            let l = NSTextField(labelWithString: (r.current ? "✓ " : "   ") + r.title + "   " + r.value)
            l.font = .monospacedDigitSystemFont(ofSize: 12, weight: r.current ? .semibold : .regular)
            l.textColor = r.current ? NSColor(srgbRed: 0.45, green: 0.95, blue: 0.55, alpha: 1) : .white
            l.lineBreakMode = .byTruncatingMiddle
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            list.addArrangedSubview(l)
            l.widthAnchor.constraint(lessThanOrEqualTo: list.widthAnchor).isActive = true
        }
    }

    @objc private func stepped(_ b: NSButton) { onStep?(Double(b.tag)) }
    @objc private func resetTapped() { onReset?() }
    @objc private func closeTapped() { onClose?() }
    // a click inside the box stays inside (the picture's click would open the camera choice)
    override func mouseDown(with event: NSEvent) {}
}
