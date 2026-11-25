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
        // v36: the value in frames and samples too, the unit the field and keys use, the presets
        var unit: Sync.Unit = .ms
        var unitValue: Double = 0          // the selected input's value in `unit`
        var readout: String = ""           // "+72.5 ms = 2.18 frames at 30 fps = 3480 samples at 48 kHz"
        var presets: [(id: String, title: String, builtIn: Bool)] = []
    }
    var onStep: ((Double) -> Void)?           // v36: a step in the current unit
    var onReset: (() -> Void)?
    var onClose: (() -> Void)?
    var onSetValue: ((Double) -> Void)?       // v36: a typed value in the current unit
    var onUnit: ((Sync.Unit) -> Void)?
    var onPresetApply: ((String) -> Void)?
    var onPresetSave: (() -> Void)?
    var onPresetRename: ((String) -> Void)?
    var onPresetDelete: ((String) -> Void)?

    private let head = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private var steps: [NSButton] = []
    private var stepValues: [Double] = [-1, -0.1, 0.1, 1]
    private let reset = NSButton()
    private let closeKey = NSButton()
    // v36
    private let field = NSTextField(string: "")
    private let unitLabel = NSTextField(labelWithString: "ms")
    private let readout = NSTextField(wrappingLabelWithString: "")
    private var unitKeys: [Sync.Unit: NSButton] = [:]
    private let presetMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyKey = NSButton(), saveKey = NSButton(), renameKey = NSButton(), deleteKey = NSButton()
    private var presetIDs: [String] = []
    private var presetBuiltIn: [Bool] = []

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
        for (i, t) in ["-1", "-0.1", "+0.1", "+1"].enumerated() {
            let b = Self.key(t, self, #selector(stepped(_:)))
            b.tag = i
            steps.append(b); keys.append(b)
        }
        // v36: the value typed in the current unit (Return applies), the unit switch, the three units side by side
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        field.alignment = .right
        field.target = self; field.action = #selector(typed)
        field.setAccessibilityTitle("VALUE")
        field.toolTip = "Type the delay in the chosen unit and press Return. + = hold this sound back; − = the sound is late against the camera: in a take it is moved earlier, live (Zoom) the picture waits for it."
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        unitLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        unitLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        var unitViews: [NSView] = []
        for (u, t) in [(Sync.Unit.ms, "MS"), (.frames, "FRAMES"), (.samples, "SAMPLES")] {
            let b = Self.key(t, self, #selector(unitTapped(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(u.rawValue)
            unitKeys[u] = b; unitViews.append(b)
        }
        let fieldRow = NSStackView(views: [field, unitLabel])
        fieldRow.orientation = .horizontal; fieldRow.spacing = 6
        let unitRow = NSStackView(views: unitViews)
        unitRow.orientation = .horizontal; unitRow.spacing = 6
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = NSColor.white.withAlphaComponent(0.8)
        readout.setAccessibilityIdentifier("sync-units")
        // v36: presets, built-in (the measured values) and his own
        presetMenu.setAccessibilityTitle("PRESETS")
        presetMenu.toolTip = "Presets: the measured values of your devices and the ones you saved. Choose one, then APPLY."
        presetMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        presetMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        Self.style(applyKey, "APPLY", self, #selector(applyTapped))
        Self.style(saveKey, "SAVE AS PRESET", self, #selector(saveTapped))
        Self.style(renameKey, "RENAME", self, #selector(renameTapped))
        Self.style(deleteKey, "DELETE", self, #selector(deleteTapped))
        applyKey.toolTip = "Apply the chosen preset to this sound input"
        saveKey.toolTip = "Save the current value as a preset (this input or any input)"
        renameKey.toolTip = "Rename the chosen preset (your own presets only)"
        deleteKey.toolTip = "Delete the chosen preset (your own presets only)"
        let presetRow = NSStackView(views: [presetMenu, applyKey])
        presetRow.orientation = .horizontal; presetRow.spacing = 6
        let presetKeys = NSStackView(views: [saveKey, renameKey, deleteKey])
        presetKeys.orientation = .horizontal; presetKeys.spacing = 6
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
        let stack = NSStackView(views: [top, value, readout, detail, fieldRow, unitRow, row, Self.heading("PRESETS"), presetRow, presetKeys,
                                         Self.heading("STORED VALUES"), list, footer])
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
            readout.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        // v36: unit, field, steps of that unit, presets
        readout.stringValue = m.readout
        readout.isHidden = m.readout.isEmpty
        stepValues = Sync.steps(m.unit)
        for (i, b) in steps.enumerated() where i < stepValues.count {
            let v = stepValues[i]
            let t = (v > 0 ? "+" : "") + (v == v.rounded() ? String(Int(v)) : String(v))
            if b.attributedTitle.string != t {
                b.attributedTitle = NSAttributedString(string: t, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
                b.setAccessibilityTitle(t)
            }
        }
        unitLabel.stringValue = m.unit == .ms ? "ms" : m.unit.rawValue
        for (u, b) in unitKeys {
            b.layer?.backgroundColor = (u == m.unit ? NSColor.systemGreen.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.16)).cgColor
            b.setAccessibilityValue(u == m.unit ? "selected" : "")
        }
        if window?.firstResponder !== field.currentEditor() { field.stringValue = m.adjustable ? Sync.plain(m.unitValue, m.unit) : "—" }
        field.isEditable = m.adjustable; field.isEnabled = m.adjustable
        field.setAccessibilityValue(field.stringValue)
        let keep = presetMenu.indexOfSelectedItem >= 0 && presetMenu.indexOfSelectedItem < presetIDs.count ? presetIDs[presetMenu.indexOfSelectedItem] : nil
        presetMenu.removeAllItems()
        presetIDs = m.presets.map { $0.id }; presetBuiltIn = m.presets.map { $0.builtIn }
        for p in m.presets { presetMenu.addItem(withTitle: p.title) }
        if let keep, let i = presetIDs.firstIndex(of: keep) { presetMenu.selectItem(at: i) }
        presetMenu.target = self; presetMenu.action = #selector(presetChosen)
        presetChosen()
        applyKey.isEnabled = m.adjustable; applyKey.alphaValue = m.adjustable ? 1 : 0.4
        saveKey.isEnabled = m.adjustable; saveKey.alphaValue = m.adjustable ? 1 : 0.4
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

    @objc private func stepped(_ b: NSButton) { if b.tag < stepValues.count { onStep?(stepValues[b.tag]) } }
    @objc private func typed() {
        let t = field.stringValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
        if let v = Double(t) { onSetValue?(v) } else { NSSound.beep() }
        window?.makeFirstResponder(nil)
    }
    @objc private func unitTapped(_ b: NSButton) {
        if let id = b.identifier?.rawValue, let u = Sync.Unit(rawValue: id) { window?.makeFirstResponder(nil); onUnit?(u) }
    }
    private var chosenPreset: (id: String, builtIn: Bool)? {
        let i = presetMenu.indexOfSelectedItem
        return i >= 0 && i < presetIDs.count ? (presetIDs[i], presetBuiltIn[i]) : nil
    }
    @objc private func presetChosen() {
        let own = chosenPreset.map { !$0.builtIn } ?? false
        for b in [renameKey, deleteKey] { b.isEnabled = own; b.alphaValue = own ? 1 : 0.4 }
    }
    @objc private func applyTapped() { if let p = chosenPreset { onPresetApply?(p.id) } }
    @objc private func saveTapped() { onPresetSave?() }
    @objc private func renameTapped() { if let p = chosenPreset, !p.builtIn { onPresetRename?(p.id) } }
    @objc private func deleteTapped() { if let p = chosenPreset, !p.builtIn { onPresetDelete?(p.id) } }
    @objc private func resetTapped() { onReset?() }
    @objc private func closeTapped() { onClose?() }
    // a click inside the box stays inside (the picture's click would open the camera choice)
    override func mouseDown(with event: NSEvent) {}
}
