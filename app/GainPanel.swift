import AppKit

// v31, 25.11.2026: the GAIN overlay, the SYNC box's look and place (SyncPanel.swift). Marko: "Second click is opening
// dialogue for setting up ... Just to press auto gain and then it adjust the gain level. It's not compressor ... Or you can
// also add small gear next to the audio to open this auto gain thing." The chosen input's level (peak, RMS, peak hold,
// CLIP), its gain in dB with a slider and -1 +1, AUTO GAIN, UNDO, RESET, the take's audio format (AAC or 32-bit float), CLOSE.
final class GainPanel: NSView {
    struct Model {
        var sound: String            // "RØDE NT1 5th Gen (A)" or "No sound"
        var db: Double
        var minDB: Double            // -36, or lower when the device's own volume reaches lower
        var detail: String           // hardware / digital, the device's range
        var adjustable: Bool
        var autoRunning: Bool
        var canUndo: Bool
        var note: String             // the auto gain's words
        var floatTakes: Bool
        var formatEnabled: Bool
        var footer: String
        // v40: the INSERT of this microphone (Insert.swift)
        var insertOn = false
        var insertEnabled = false
        var sends: [(uid: String, name: String)] = []
        var returns: [(uid: String, name: String)] = []
        var send = "", ret = ""
        var insertLatency = ""       // "insert latency 23.4 ms = 0.70 frames = 1123 samples · ..."
        var insertNote = ""          // state, bypass reason, warnings
        var manual = ""              // the manual override in ms, "" = measured
        var measuring = false
    }
    var onSet: ((Double) -> Void)?
    var onStep: ((Double) -> Void)?
    var onAuto: (() -> Void)?
    var onUndo: (() -> Void)?
    var onReset: (() -> Void)?
    var onFormat: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onInsert: ((Bool) -> Void)?
    var onInsertSend: ((String) -> Void)?
    var onInsertReturn: ((String) -> Void)?
    var onInsertMeasure: (() -> Void)?
    var onInsertManual: ((String) -> Void)?

    let meterView = GainMeterView()
    private let head = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let readout = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let slider = NSSlider(value: 0, minValue: Gain.minDB, maxValue: Gain.maxDB, target: nil, action: nil)
    private let minus = NSButton(), plus = NSButton()
    private let autoKey = NSButton(), undoKey = NSButton(), resetKey = NSButton(), closeKey = NSButton()
    private let aacKey = NSButton(), floatKey = NSButton()
    // v40: INSERT
    private let insertKey = NSButton(), measureKey = NSButton()
    private let sendMenu = NSPopUpButton(frame: .zero, pullsDown: false), returnMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let insertLatency = NSTextField(wrappingLabelWithString: "")
    private let insertNote = NSTextField(wrappingLabelWithString: "")
    private let insertHelp = NSTextField(wrappingLabelWithString: InsertEngine.help)
    private let manualField = NSTextField(string: "")
    private var sendUIDs: [String] = [], returnUIDs: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 10
        isHidden = true
        setAccessibilityIdentifier("gain-overlay")

        head.font = .systemFont(ofSize: 11, weight: .semibold)
        head.textColor = NSColor.white.withAlphaComponent(0.65)
        head.lineBreakMode = .byTruncatingMiddle
        head.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        value.textColor = .white
        value.setAccessibilityIdentifier("gain-value")
        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        readout.textColor = NSColor.white.withAlphaComponent(0.85)
        readout.lineBreakMode = .byTruncatingTail
        readout.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        readout.setAccessibilityIdentifier("gain-levels")
        for l in [detail, footer] {
            l.font = .systemFont(ofSize: 11, weight: .regular)
            l.textColor = NSColor.white.withAlphaComponent(0.75)
        }
        note.font = .systemFont(ofSize: 12, weight: .semibold)
        note.textColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.30, alpha: 1)
        note.setAccessibilityIdentifier("gain-note")

        Self.style(minus, "-1", self, #selector(minusTapped))
        Self.style(plus, "+1", self, #selector(plusTapped))
        slider.target = self; slider.action = #selector(slid)
        slider.isContinuous = true
        slider.setAccessibilityTitle("Gain")
        slider.setAccessibilityIdentifier("gain-slider")
        slider.controlSize = .small
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let sliderRow = NSStackView(views: [minus, slider, plus])
        sliderRow.orientation = .horizontal; sliderRow.spacing = 6

        Self.style(autoKey, "AUTO GAIN", self, #selector(autoTapped))
        autoKey.toolTip = "Listens about 5 s while you play or speak at your loudest, then sets the gain once so the peaks sit at -12 dBFS. Not a compressor."
        Self.style(undoKey, "UNDO", self, #selector(undoTapped))
        undoKey.toolTip = "Back to the gain before the last AUTO GAIN"
        Self.style(resetKey, "RESET", self, #selector(resetTapped))
        resetKey.toolTip = "0 dB: the device's own top, no digital gain"
        let keys = NSStackView(views: [autoKey, undoKey, resetKey])
        keys.orientation = .horizontal; keys.spacing = 6

        Self.style(aacKey, "AAC", self, #selector(aacTapped))
        aacKey.setAccessibilityTitle("AUDIO AAC")
        aacKey.toolTip = "Takes with AAC sound (small files)"
        Self.style(floatKey, "32-BIT FLOAT", self, #selector(floatTapped))
        floatKey.setAccessibilityTitle("AUDIO 32-BIT FLOAT")
        floatKey.toolTip = "Takes with 32-bit float sound (PCM): nothing clips, the level can be corrected later. About 0.7 GB per hour mono."
        let fmtLabel = Self.heading("TAKE AUDIO")
        let fmtRow = NSStackView(views: [fmtLabel, aacKey, floatKey])
        fmtRow.orientation = .horizontal; fmtRow.spacing = 6

        Self.style(closeKey, "CLOSE", self, #selector(closeTapped))
        closeKey.toolTip = "Close (Escape)"
        let top = NSStackView(views: [head, NSView(), closeKey])
        top.orientation = .horizontal

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.heightAnchor.constraint(equalToConstant: 16).isActive = true

        // v40: INSERT: send → the other app → return, its measured delay (plug-in delay compensation)
        Self.style(insertKey, "INSERT OFF", self, #selector(insertTapped))
        insertKey.setAccessibilityTitle("INSERT")
        insertKey.toolTip = "Send this microphone out of SEND into another app (PatchWork, Ableton Live, anything) and take it back from RETURN; the app compensates the measured delay."
        Self.style(measureKey, "MEASURE DELAY", self, #selector(measureTapped))
        measureKey.toolTip = "Plays short test bursts out of SEND (Zoom hears the dry sound meanwhile) and finds them on RETURN: the round trip is stored for this microphone."
        let insRow = NSStackView(views: [insertKey, measureKey])
        insRow.orientation = .horizontal; insRow.spacing = 6
        for (m, t) in [(sendMenu, "SEND"), (returnMenu, "RETURN")] {
            m.setAccessibilityTitle(t)
            m.target = self; m.action = t == "SEND" ? #selector(sendChosen) : #selector(returnChosen)
            m.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            m.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        }
        let sendRow = NSStackView(views: [Self.heading("SEND"), sendMenu]); sendRow.orientation = .horizontal; sendRow.spacing = 6
        let retRow = NSStackView(views: [Self.heading("RETURN"), returnMenu]); retRow.orientation = .horizontal; retRow.spacing = 6
        insertLatency.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        insertLatency.textColor = NSColor.white.withAlphaComponent(0.85)
        insertLatency.setAccessibilityIdentifier("insert-latency")
        insertNote.font = .systemFont(ofSize: 11, weight: .semibold)
        insertNote.textColor = NSColor(srgbRed: 1, green: 0.78, blue: 0.30, alpha: 1)
        insertNote.setAccessibilityIdentifier("insert-note")
        insertHelp.font = .systemFont(ofSize: 10, weight: .regular)
        insertHelp.textColor = NSColor.white.withAlphaComponent(0.6)
        manualField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        manualField.placeholderString = "measured"
        manualField.setAccessibilityTitle("INSERT MANUAL MS")
        manualField.toolTip = "Your own insert delay in ms (Return applies); empty = the measured one"
        manualField.target = self; manualField.action = #selector(manualTyped)
        manualField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let manRow = NSStackView(views: [Self.heading("MANUAL"), manualField, Self.heading("ms (empty = measured)")])
        manRow.orientation = .horizontal; manRow.spacing = 6

        let stack = NSStackView(views: [top, value, detail, meterView, readout, sliderRow, keys, note, fmtRow,
                                        Self.heading("INSERT (send → other app → return)"), insRow, sendRow, retRow, insertLatency,
                                        manRow, insertNote, insertHelp, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setCustomSpacing(2, after: value)
        stack.setCustomSpacing(3, after: meterView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            meterView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            readout.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sliderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            insertLatency.widthAnchor.constraint(equalTo: stack.widthAnchor),
            insertNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            insertHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func heading(_ t: String) -> NSTextField {
        let h = NSTextField(labelWithString: t)
        h.font = .systemFont(ofSize: 11, weight: .semibold)
        h.textColor = NSColor.white.withAlphaComponent(0.6)
        return h
    }
    /// SyncPanel's key: bold letters, no border, a soft blob behind
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
    private static func mark(_ b: NSButton, _ on: Bool) {
        b.layer?.backgroundColor = (on ? NSColor(srgbRed: 0.20, green: 0.62, blue: 0.35, alpha: 0.85) : NSColor.white.withAlphaComponent(0.16)).cgColor
        b.layer?.borderWidth = on ? 1.5 : 0
        b.layer?.borderColor = NSColor(srgbRed: 0.45, green: 0.95, blue: 0.55, alpha: 1).cgColor
        b.setAccessibilityValue(on ? "on" : "off")
    }

    func update(_ m: Model) {
        head.stringValue = "GAIN · " + m.sound
        value.stringValue = Gain.text(m.db)
        value.setAccessibilityValue(Gain.text(m.db))
        detail.stringValue = m.detail
        if slider.minValue != m.minDB { slider.minValue = m.minDB }
        if !slider.isHighlighted { slider.doubleValue = m.db }
        slider.setAccessibilityValue(Gain.text(m.db))
        for b in [minus, plus, resetKey] { b.isEnabled = m.adjustable && !m.autoRunning; b.alphaValue = m.adjustable && !m.autoRunning ? 1 : 0.4 }
        slider.isEnabled = m.adjustable && !m.autoRunning
        autoKey.isEnabled = m.adjustable; autoKey.alphaValue = m.adjustable ? 1 : 0.4
        let autoTitle = m.autoRunning ? "STOP AUTO" : "AUTO GAIN"
        if autoKey.attributedTitle.string != autoTitle {
            autoKey.attributedTitle = NSAttributedString(string: autoTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
        }
        autoKey.setAccessibilityTitle("AUTO GAIN")
        autoKey.setAccessibilityValue(m.autoRunning ? "running" : "idle")
        Self.mark(autoKey, m.autoRunning)
        undoKey.isEnabled = m.canUndo && !m.autoRunning; undoKey.alphaValue = undoKey.isEnabled ? 1 : 0.4
        note.stringValue = m.note
        note.isHidden = m.note.isEmpty
        Self.mark(aacKey, !m.floatTakes); Self.mark(floatKey, m.floatTakes)
        for b in [aacKey, floatKey] { b.isEnabled = m.formatEnabled; b.alphaValue = m.formatEnabled ? 1 : 0.5 }
        footer.stringValue = m.footer
        // v40: INSERT
        let it = m.insertOn ? "INSERT ON" : "INSERT OFF"
        if insertKey.attributedTitle.string != it {
            insertKey.attributedTitle = NSAttributedString(string: it, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
        }
        insertKey.setAccessibilityTitle("INSERT")
        Self.mark(insertKey, m.insertOn)
        insertKey.isEnabled = m.insertEnabled; insertKey.alphaValue = m.insertEnabled ? 1 : 0.4
        measureKey.isEnabled = m.insertOn && !m.measuring; measureKey.alphaValue = measureKey.isEnabled ? 1 : 0.4
        Self.mark(measureKey, m.measuring)
        if sendUIDs != m.sends.map({ $0.uid }) {
            sendMenu.removeAllItems(); sendMenu.addItems(withTitles: m.sends.map { $0.name }); sendUIDs = m.sends.map { $0.uid }
        }
        if returnUIDs != m.returns.map({ $0.uid }) {
            returnMenu.removeAllItems(); returnMenu.addItems(withTitles: m.returns.map { $0.name }); returnUIDs = m.returns.map { $0.uid }
        }
        if let i = sendUIDs.firstIndex(of: m.send) { sendMenu.selectItem(at: i) }
        if let i = returnUIDs.firstIndex(of: m.ret) { returnMenu.selectItem(at: i) }
        for x in [sendMenu, returnMenu] { x.isEnabled = m.insertEnabled }
        insertLatency.stringValue = m.insertLatency
        insertLatency.isHidden = m.insertLatency.isEmpty
        insertNote.stringValue = m.insertNote
        insertNote.isHidden = m.insertNote.isEmpty
        if window?.firstResponder !== manualField.currentEditor() { manualField.stringValue = m.manual }
        manualField.isEnabled = m.insertEnabled
    }

    /// the meter line under the value: "peak -14.2  RMS -28.5  hold -12.0 dBFS  CLIP 0"
    func showLevels(peak: Double, rms: Double, hold: Double, clip: Bool, clips: Int) {
        meterView.set(peak: peak, rms: rms, hold: hold, clip: clip)
        let f = { (x: Double) in x <= -119 ? "-inf" : String(format: "%.1f", x) }
        readout.stringValue = "peak \(f(peak))  RMS \(f(rms))  hold \(f(hold)) dBFS  ·  clips \(clips)"
        readout.setAccessibilityValue(readout.stringValue)
    }

    @objc private func slid() { onSet?(Gain.clamp(slider.doubleValue, lo: slider.minValue)) }
    @objc private func minusTapped() { onStep?(-1) }
    @objc private func plusTapped() { onStep?(1) }
    @objc private func autoTapped() { onAuto?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func resetTapped() { onReset?() }
    @objc private func aacTapped() { onFormat?(false) }
    @objc private func floatTapped() { onFormat?(true) }
    @objc private func closeTapped() { onClose?() }
    @objc private func insertTapped() { onInsert?(insertKey.attributedTitle.string != "INSERT ON") }
    @objc private func measureTapped() { onInsertMeasure?() }
    @objc private func sendChosen() { let i = sendMenu.indexOfSelectedItem; if i >= 0 && i < sendUIDs.count { onInsertSend?(sendUIDs[i]) } }
    @objc private func returnChosen() { let i = returnMenu.indexOfSelectedItem; if i >= 0 && i < returnUIDs.count { onInsertReturn?(returnUIDs[i]) } }
    @objc private func manualTyped() { onInsertManual?(manualField.stringValue); window?.makeFirstResponder(nil) }
    override func mouseDown(with event: NSEvent) {}
}

/// a horizontal meter, -60 … 0 dBFS: the RMS bar, the peak as a white line, the peak hold as a thin tick, -12 (the auto
/// gain's target) and -6 marked, CLIP as a red lamp at the right end (held 2 s by the owner)
final class GainMeterView: NSView {
    static let floor = -60.0
    private var peak = -120.0, rms = -120.0, hold = -120.0, clip = false
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    func set(peak: Double, rms: Double, hold: Double, clip: Bool) {
        self.peak = peak; self.rms = rms; self.hold = hold; self.clip = clip
        needsDisplay = true
        setAccessibilityValue(String(format: "peak %.1f dBFS, RMS %.1f dBFS%@", peak, rms, clip ? ", CLIP" : ""))
    }
    override func draw(_ r: NSRect) {
        let lamp: CGFloat = 34
        let w = bounds.width - lamp - 4, h = bounds.height
        let x = { (db: Double) -> CGFloat in CGFloat(max(0, min(1, (db - Self.floor) / -Self.floor))) * w }
        NSColor(white: 1, alpha: 0.10).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        let c = rms > -6 ? NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)
            : rms > -18 ? NSColor(srgbRed: 1, green: 0.702, blue: 0, alpha: 1) : NSColor(srgbRed: 0, green: 0.878, blue: 0.627, alpha: 1)
        c.setFill(); NSRect(x: 0, y: 2, width: x(rms), height: h - 4).fill()
        NSColor(white: 1, alpha: 0.9).setFill(); NSRect(x: max(0, x(peak) - 1), y: 0, width: 2, height: h).fill()
        NSColor(srgbRed: 1, green: 0.78, blue: 0.30, alpha: 1).setFill(); NSRect(x: max(0, x(hold) - 1), y: 0, width: 2, height: h).fill()
        NSColor(white: 1, alpha: 0.45).setFill()
        for db in [-12.0, -6.0] { NSRect(x: x(db), y: 0, width: 1, height: h).fill() }
        let lr = NSRect(x: w + 4, y: 0, width: lamp, height: h)
        (clip ? NSColor(srgbRed: 1, green: 0.15, blue: 0.12, alpha: 1) : NSColor(white: 1, alpha: 0.12)).setFill()
        NSBezierPath(roundedRect: lr, xRadius: 3, yRadius: 3).fill()
        let t = NSAttributedString(string: "CLIP", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: clip ? NSColor.white : NSColor(white: 1, alpha: 0.5)])
        let s = t.size()
        t.draw(at: NSPoint(x: lr.midX - s.width / 2, y: lr.midY - s.height / 2))
    }
}
