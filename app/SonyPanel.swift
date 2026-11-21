// SonyPanel.swift (v21): the SONY overlay. A see-through layer over the live picture, under the top bar (never over it),
// with every setting the camera reports as native AppKit controls: Picture Profile first and big (PP1 and the slot the
// camera reports as S-Log3 / S-Gamut3.Cine), REC, AEL / FEL / AWBL, then the main settings, then every other setting the
// camera offers. Each control shows the camera's current value and changes it through PTP; a setting the camera does not
// allow now (IsEnabled 0 or 2, or read-only) is grey. Everything wraps with the window width and scrolls; nothing is cut.
// The SONY key or Escape hides it.
import AppKit

private let white = NSColor.white
private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = white, lines: Int = 1) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.maximumNumberOfLines = lines
    l.lineBreakMode = lines == 1 ? .byClipping : .byWordWrapping
    l.cell?.wraps = lines != 1
    return l
}

/// a flipped view laid out by hand: rows of items that wrap with the width
private final class FlowDoc: NSView {
    override var isFlipped: Bool { true }
}

/// one setting: its name (up to two lines) and a pop-up (enumeration), − value + (range) or the value (read only)
private final class Card: NSView {
    static let size = NSSize(width: 214, height: 62)
    let code: UInt16
    let name: NSTextField
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    let minus = NSButton(title: "−", target: nil, action: nil)
    let plus = NSButton(title: "+", target: nil, action: nil)
    let value = label("", size: 13, weight: .semibold)
    var onPick: ((UInt64) -> Void)?
    private var shown: [UInt64] = []
    private var prop: SonyProp?

    init(code: UInt16) {
        self.code = code
        name = label(SonyLabels.name(code).uppercased(), size: 10, weight: .semibold, color: white.withAlphaComponent(0.65), lines: 2)
        super.init(frame: NSRect(origin: .zero, size: Card.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.cornerRadius = 6
        name.toolTip = SonyLabels.name(code)
        for v in [name, popup, minus, plus, value] { addSubview(v) }
        popup.controlSize = .small; popup.font = .systemFont(ofSize: 12)
        popup.target = self; popup.action = #selector(picked)
        popup.setAccessibilityLabel(SonyLabels.name(code))
        popup.setAccessibilityIdentifier(String(format: "sony-%04X", code))
        for (b, d) in [(minus, -1), (plus, 1)] {
            b.bezelStyle = .rounded; b.controlSize = .small; b.tag = d
            b.target = self; b.action = #selector(step(_:))
            b.setAccessibilityLabel("\(SonyLabels.name(code)) \(d < 0 ? "down" : "up")")
        }
        value.alignment = .center
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width - 16
        name.frame = NSRect(x: 8, y: 4, width: w, height: 26)
        popup.frame = NSRect(x: 6, y: 32, width: w + 4, height: 24)
        minus.frame = NSRect(x: 6, y: 32, width: 34, height: 24)
        plus.frame = NSRect(x: bounds.width - 40, y: 32, width: 34, height: 24)
        value.frame = NSRect(x: 42, y: 35, width: bounds.width - 84, height: 18)
        if prop?.form != 1 && popup.isHidden { value.frame = NSRect(x: 8, y: 35, width: w, height: 18) }
    }
    override var isFlipped: Bool { true }

    func update(_ p: SonyProp) {
        prop = p
        let live = p.settable
        let cur = p.value
        if p.form == 2 && p.getSet == 1 && SonyProp.size(p.type) != nil {
            popup.isHidden = false; minus.isHidden = true; plus.isHidden = true; value.isHidden = true
            var list = p.options
            if !list.contains(cur) { list.insert(cur, at: 0) }
            if list != shown {
                popup.removeAllItems()
                for v in list {
                    popup.addItem(withTitle: SonyLabels.label(code, v, type: p.type))
                    popup.lastItem?.representedObject = NSNumber(value: v)
                    if !p.options.contains(v) { popup.lastItem?.isEnabled = false }
                }
                shown = list
            }
            popup.autoenablesItems = false
            if let i = list.firstIndex(of: cur) { popup.selectItem(at: i) }
            popup.isEnabled = live
        } else if p.form == 1 && p.getSet == 1 && SonyProp.size(p.type) != nil {
            popup.isHidden = true; minus.isHidden = false; plus.isHidden = false; value.isHidden = false
            value.stringValue = SonyLabels.label(code, cur, type: p.type)
            minus.isEnabled = live; plus.isEnabled = live
        } else {
            popup.isHidden = true; minus.isHidden = true; plus.isHidden = true; value.isHidden = false
            value.stringValue = p.string ?? SonyLabels.label(code, cur, type: p.type)
        }
        value.textColor = live ? white : NSColor.gray
        name.textColor = live ? white.withAlphaComponent(0.7) : NSColor.gray
        let why = p.getSet == 0 ? "read only" : p.enabled == 2 ? "display only now" : p.enabled == 0 ? "not available now" : "settable"
        toolTip = "\(SonyLabels.name(code)) (\(sonyHex(code))): \(why)"
        needsLayout = true
    }

    @objc private func picked() {
        guard let n = popup.selectedItem?.representedObject as? NSNumber else { return }
        onPick?(n.uint64Value)
    }
    @objc private func step(_ b: NSButton) {
        guard let p = prop else { return }
        let st = max(1, p.rangeStep)
        if p.isSigned {
            let cur = p.signedValue, s = Int64(bitPattern: st)
            let lo = SonyProp.signed(p.rangeMin, p.type), hi = SonyProp.signed(p.rangeMax, p.type)
            let next = min(hi, max(lo, cur + (b.tag < 0 ? -s : s)))
            onPick?(UInt64(bitPattern: next) & mask(p.type))
        } else {
            let cur = p.value
            let next = b.tag < 0 ? (cur >= p.rangeMin &+ st ? cur - st : p.rangeMin) : min(p.rangeMax, cur &+ st)
            onPick?(next)
        }
    }
    private func mask(_ t: UInt16) -> UInt64 {
        switch SonyProp.size(t) ?? 8 { case 1: return 0xFF; case 2: return 0xFFFF; case 4: return 0xFFFF_FFFF; default: return .max }
    }
}

final class SonyPanel: NSView {
    let link: SonyLink
    var onClose: (() -> Void)?
    private let scroll = NSScrollView()
    private let doc = FlowDoc()

    // header
    private let title = label("SONY", size: 13, weight: .bold)
    private let status = label("", size: 12, color: white.withAlphaComponent(0.85), lines: 0)
    // v23: the staged check, one measured line per stage, and the two keys it may need
    private let stages = label("", size: 11, color: white.withAlphaComponent(0.75), lines: 0)
    private let takeKey = NSButton(title: "TAKE CONTROL (closes Imaging Edge Remote)", target: nil, action: nil)
    private let checkKey = NSButton(title: "CHECK", target: nil, action: nil)
    private let connectKey = NSButton(title: "CONNECT", target: nil, action: nil)
    private let address = NSTextField(string: "")
    private let demoKey = NSButton(title: "DEMO", target: nil, action: nil)
    private let closeKey = NSButton(title: "HIDE", target: nil, action: nil)
    // login (Access Authentication)
    private let finger = label("", size: 11, color: white.withAlphaComponent(0.85), lines: 4)
    private let userField = NSTextField(string: "")
    private let passField = NSSecureTextField(string: "")
    private let loginKey = NSButton(title: "SAME AS CAMERA · CONNECT", target: nil, action: nil)
    // picture profile
    private let ppHead = label("PICTURE PROFILE", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private let pp1Key = NSButton(title: "PP1", target: nil, action: nil)
    private let slogKey = NSButton(title: "S-LOG3", target: nil, action: nil)
    private let ppPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scanKey = NSButton(title: "READ SLOTS", target: nil, action: nil)
    // buttons
    private let keysHead = label("CAMERA BUTTONS", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private let recKey = NSButton(title: "● REC", target: nil, action: nil)
    private let aelKey = NSButton(title: "AEL", target: nil, action: nil)
    private let felKey = NSButton(title: "FEL", target: nil, action: nil)
    private let awblKey = NSButton(title: "AWBL", target: nil, action: nil)
    private let facts = label("", size: 12, color: white.withAlphaComponent(0.85), lines: 2)
    // settings
    private let mainHead = label("SETTINGS", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private let moreHead = label("EVERY OTHER SETTING THE CAMERA OFFERS", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private var cards: [UInt16: Card] = [:]
    private var mainCodes: [UInt16] = []
    private var moreCodes: [UInt16] = []
    private var ppShown: [UInt64] = []

    /// the settings Marko named first, in this order (when the camera reports them)
    static let main: [UInt16] = [0x500E, 0xD20D, 0x5007, 0xD21E, 0x5010, 0x5005, 0xD20F, 0xD201, 0x500B, 0x500A, 0xD22C,
                                 0xD253, 0xD203, 0xD288, 0xD287, 0xD0FA, 0xD0E1, 0xD0E9, 0xD25A]
    /// shown as facts or buttons, not as cards
    static let skip: Set<UInt16> = [0xD23F, 0xD21D, 0xD217, 0xD21F, 0xD24E, 0xD218, 0xD24A]

    init(link: SonyLink) {
        self.link = link
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        isHidden = true
        setAccessibilityIdentifier("sony-overlay")
        setAccessibilityLabel("Sony camera controls")

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor)])

        func key(_ b: NSButton, _ sel: Selector, _ id: String, _ tip: String, big: Bool = false) {
            b.bezelStyle = .rounded
            b.controlSize = big ? .large : .regular
            if big { b.font = .systemFont(ofSize: 15, weight: .bold) } else { b.font = .systemFont(ofSize: 12, weight: .semibold) }
            b.target = self; b.action = sel
            b.setAccessibilityIdentifier(id); b.toolTip = tip
            doc.addSubview(b)
        }
        key(connectKey, #selector(connectTapped), "sony-connect", "Find the Sony on the network and connect (or disconnect)")
        key(takeKey, #selector(takeTapped), "sony-takecontrol", "Imaging Edge Remote holds the camera's USB connection: close it and control the camera from this window")
        key(checkKey, #selector(checkTapped), "sony-check", "Check every stage again: the Mac's network, the camera's address, SSDP, the remote ports, the USB cable")
        key(demoKey, #selector(demoTapped), "sony-demo", "A pretend camera: shows every control without touching the Sony")
        key(closeKey, #selector(hideTapped), "sony-hide", "Hide the Sony controls (SONY key or Escape)")
        key(loginKey, #selector(loginTapped), "sony-login", "The fingerprint above is the same as on the camera's Access Authen. Info: save it, the user and password, and connect")
        key(pp1Key, #selector(pp1Tapped), "sony-pp1", "Picture Profile 1 (shooting)", big: true)
        key(slogKey, #selector(slogTapped), "sony-slog3", "The Picture Profile slot the camera reports as S-Log3 with S-Gamut3.Cine", big: true)
        key(scanKey, #selector(scanTapped), "sony-scan", "Select each Picture Profile slot in turn to read its gamma and color mode, then put back the one selected now")
        key(recKey, #selector(recTapped), "sony-rec", "Start or stop recording on the camera's card", big: true)
        key(aelKey, #selector(aelTapped), "sony-ael", "AEL button (AE lock)")
        key(felKey, #selector(felTapped), "sony-fel", "FEL button (flash exposure lock)")
        key(awblKey, #selector(awblTapped), "sony-awbl", "AWBL button (auto white balance lock)")
        for b in [pp1Key, slogKey, recKey] { b.setContentHuggingPriority(.required, for: .horizontal) }

        ppPopup.target = self; ppPopup.action = #selector(ppPicked)
        ppPopup.setAccessibilityLabel("Picture Profile"); ppPopup.setAccessibilityIdentifier("sony-D23F")
        ppPopup.font = .systemFont(ofSize: 13)
        doc.addSubview(ppPopup)

        address.placeholderString = "camera address (192.168.1.x)"
        address.stringValue = link.savedAddress
        address.setAccessibilityLabel("Camera address"); address.setAccessibilityIdentifier("sony-address")
        address.target = self; address.action = #selector(connectTapped)
        userField.placeholderString = "user (Access Authen. Info)"
        userField.stringValue = link.user
        userField.setAccessibilityLabel("Camera user")
        passField.placeholderString = "password"
        passField.setAccessibilityLabel("Camera password")
        stages.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        stages.setAccessibilityIdentifier("sony-stages")
        for v in [title, status, stages, address, finger, userField, passField, ppHead, keysHead, facts, mainHead, moreHead] { doc.addSubview(v) }
        title.setAccessibilityLabel("Sony")
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    // a click on the dim area does nothing (no accidental close); the window still moves by its background
    override func mouseDown(with event: NSEvent) {}

    // MARK: values from the camera
    func update() {
        let p = link.props
        let model = link.found?.model ?? (link.savedModel.isEmpty ? "α7 V" : link.savedModel)
        title.stringValue = "SONY  " + model
        var s = link.busy ?? link.message
        if s.isEmpty { s = "Not connected. CONNECT finds the camera on the Mantra network; DEMO shows the controls without it." }
        if let last = link.log.last, last != s, link.connected { s += "\n" + last }
        status.stringValue = s
        // v23: the stages stay visible while not connected; TAKE CONTROL only while another program holds the cable
        let d = link.diagnosis
        stages.isHidden = link.connected || d == nil
        stages.stringValue = d?.lines.joined(separator: "\n") ?? ""
        takeKey.isHidden = link.phase != .usbBusy
        if let n = d?.usb?.ownerName, !n.isEmpty, d?.usb?.heldByOther == true { takeKey.title = "TAKE CONTROL (closes \(n))" }
        checkKey.isHidden = link.connected || link.phase == .connecting || link.phase == .searching
        connectKey.title = link.connected || link.phase == .connecting || link.phase == .searching ? "DISCONNECT" : "CONNECT"
        demoKey.isHidden = link.connected && !link.demo
        demoKey.title = link.demo ? "DEMO ✓" : "DEMO"

        // login
        let login = link.phase == .needLogin
        for v in [finger, userField, passField, loginKey] as [NSView] { v.isHidden = !login }
        if login {
            let k = link.hostKey.map { "Camera fingerprint (compare with MENU → Network → Network Option → Access Authen. Info):\n" + $0.sha256.joined(separator: "\n") }
            finger.stringValue = k ?? "The fingerprint was approved before. Type the user and password from Access Authen. Info."
        }

        // picture profile
        let pp = p[0xD23F]
        let ppLive = pp?.settable ?? false
        let cur = pp?.value
        func slotTitle(_ s: UInt64) -> String {
            if let k = link.slots[s] { return "\(SonyLabels.ppShort(s)) · \(SonyLabels.gamma(k.gamma)) / \(SonyLabels.colorMode(k.color))" }
            return SonyLabels.ppShort(s)
        }
        pp1Key.title = link.slots[1].map { "PP1 · \(SonyLabels.gamma($0.gamma))" } ?? "PP1"
        if let s = link.slog3Slot { slogKey.title = "S-Log3 · S-Gamut3.Cine (\(SonyLabels.ppShort(s)))"; slogKey.isEnabled = ppLive && link.busy == nil }
        else { slogKey.title = "S-Log3: READ SLOTS first"; slogKey.isEnabled = ppLive && link.busy == nil }
        pp1Key.isEnabled = ppLive && link.busy == nil && (pp?.options.contains(1) ?? false)
        tint(pp1Key, on: cur == 1)
        tint(slogKey, on: cur != nil && cur == link.slog3Slot)
        scanKey.isEnabled = ppLive && link.busy == nil && !link.recording
        if let pp {
            var list = pp.options
            if !list.contains(pp.value) { list.insert(pp.value, at: 0) }
            let titles = list.map(slotTitle)
            if list != ppShown || ppPopup.itemTitles != titles {
                ppPopup.removeAllItems()
                for (v, t) in zip(list, titles) { ppPopup.addItem(withTitle: t); ppPopup.lastItem?.representedObject = NSNumber(value: v) }
                ppShown = list
            }
            if let i = list.firstIndex(of: pp.value) { ppPopup.selectItem(at: i) }
            ppPopup.isEnabled = ppLive && link.busy == nil
        } else { ppPopup.removeAllItems(); ppPopup.addItem(withTitle: "Picture Profile —"); ppPopup.isEnabled = false; ppShown = [] }
        ppPopup.sizeToFit()

        // buttons and facts
        let on = link.connected
        recKey.isEnabled = on
        recKey.title = link.recording ? "■ STOP REC" : "● REC"
        tint(recKey, on: link.recording, color: .systemRed)
        func lock(_ b: NSButton, _ name: String, _ code: UInt16) {
            let locked = p[code]?.value == 2
            b.title = locked ? "\(name) ✓" : name
            b.isEnabled = on
            tint(b, on: locked)
        }
        lock(aelKey, "AEL", 0xD217); lock(felKey, "FEL", 0xD21F); lock(awblKey, "AWBL", 0xD24E)
        var f: [String] = []
        if let r = p[0xD21D] { f.append(r.value == 1 ? "● REC" : r.value == 3 ? "waiting" : r.value == 2 ? "REC failed" : "STBY") }
        if let b = p[0xD218], b.enabled != 0 { f.append("battery " + SonyLabels.label(0xD218, b.value)) }
        if let c = p[0xD24A], c.enabled != 0 { f.append("card " + SonyLabels.label(0xD24A, c.value)) }
        if !p.isEmpty { f.append("\(p.values.filter { $0.getSet == 1 }.count) settings the Mac can set") }
        facts.stringValue = f.joined(separator: "   ·   ")

        // cards
        let codes = Set(p.keys)
        mainCodes = Self.main.filter { codes.contains($0) }
        let mainSet = Set(mainCodes)
        moreCodes = p.values.filter { $0.getSet == 1 && !mainSet.contains($0.code) && !Self.skip.contains($0.code) }
            .map(\.code).sorted { (SonyLabels.order[$0] ?? 99_999, $0) < (SonyLabels.order[$1] ?? 99_999, $1) }
        let wanted = Set(mainCodes + moreCodes)
        for (c, card) in cards where !wanted.contains(c) { card.removeFromSuperview(); cards[c] = nil }
        for c in mainCodes + moreCodes {
            let card: Card
            if let k = cards[c] { card = k } else {
                card = Card(code: c)
                card.onPick = { [weak self] v in self?.link.setValue(c, v) }
                doc.addSubview(card); cards[c] = card
            }
            if let prop = p[c] { card.update(prop) }
        }
        mainHead.isHidden = mainCodes.isEmpty
        moreHead.isHidden = moreCodes.isEmpty
        moreHead.stringValue = "EVERY OTHER SETTING THE CAMERA OFFERS (\(moreCodes.count))"
        needsLayout = true
    }

    /// the current one: a coloured border and title (v22: bezelColor alone was not redrawn in an inactive window)
    private func tint(_ b: NSButton, on: Bool, color: NSColor = .systemGreen) {
        b.bezelColor = on ? color : nil
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.borderWidth = on ? 2 : 0
        b.layer?.borderColor = color.cgColor
        let text: NSColor = !b.isEnabled ? .disabledControlTextColor : on ? color : .controlTextColor
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: text, .font: b.font ?? NSFont.systemFont(ofSize: 12, weight: .semibold)])
        b.setAccessibilityValue(on ? "current" : nil)
    }

    // MARK: layout: everything in rows that wrap with the width
    override func layout() {
        super.layout()
        let width = max(300, scroll.contentSize.width)
        let m: CGFloat = 16, gap: CGFloat = 8
        var y: CGFloat = 12
        func fit(_ v: NSView) -> NSSize {
            if let c = v as? NSControl { c.sizeToFit() }
            var s = v.fittingSize
            if v === address || v === userField || v === passField { s = NSSize(width: 230, height: 24) }
            return NSSize(width: min(s.width, width - 2 * m), height: max(s.height, 22))
        }
        /// a row of items that wraps
        func row(_ items: [NSView], spacing: CGFloat = gap) {
            var x = m, h: CGFloat = 0
            for v in items where !v.isHidden {
                let s = fit(v)
                if x > m && x + s.width > width - m { x = m; y += h + spacing; h = 0 }
                v.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
                x += s.width + spacing; h = max(h, s.height)
            }
            y += h + 10
        }
        /// a text that wraps to the full width
        func text(_ l: NSTextField) {
            guard !l.isHidden, !l.stringValue.isEmpty else { return }
            l.preferredMaxLayoutWidth = width - 2 * m
            let h = l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 2 * m, height: 1000)).height ?? 18
            l.frame = NSRect(x: m, y: y, width: width - 2 * m, height: ceil(h))
            y += ceil(h) + 8
        }
        func grid(_ codes: [UInt16]) {
            let cw = Card.size.width, ch = Card.size.height
            let cols = max(1, Int((width - 2 * m + gap) / (cw + gap)))
            let w = min(cw * 1.4, (width - 2 * m - CGFloat(cols - 1) * gap) / CGFloat(cols))   // cards fill the row
            for (i, c) in codes.enumerated() {
                guard let card = cards[c] else { continue }
                let col = i % cols, r = i / cols
                card.frame = NSRect(x: m + CGFloat(col) * (w + gap), y: y + CGFloat(r) * (ch + gap), width: w, height: ch)
            }
            if !codes.isEmpty { y += CGFloat((codes.count + cols - 1) / cols) * (ch + gap) + 6 }
        }
        row([title, connectKey, address, demoKey, closeKey])
        text(status)
        row([takeKey, checkKey])
        text(stages)
        if !finger.isHidden { text(finger); row([userField, passField, loginKey]) }
        text(ppHead); row([pp1Key, slogKey, ppPopup, scanKey])
        text(keysHead); row([recKey, aelKey, felKey, awblKey])
        text(facts)
        if !mainHead.isHidden { text(mainHead); grid(mainCodes) }
        if !moreHead.isHidden { text(moreHead); grid(moreCodes) }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentSize.height))
    }

    // MARK: actions
    @objc private func connectTapped() {
        link.savedAddress = address.stringValue
        if link.connected || link.phase == .connecting || link.phase == .searching { link.disconnect() } else { link.findAndConnect() }
    }
    @objc private func demoTapped() { if link.demo { link.disconnect() } else if !link.connected { link.startDemo() } }
    @objc private func hideTapped() { onClose?() }
    @objc private func takeTapped() { link.takeControl() }
    @objc private func checkTapped() { link.savedAddress = address.stringValue; link.check() }
    @objc private func loginTapped() {
        link.approveAndConnect(user: userField.stringValue, password: passField.stringValue)
        passField.stringValue = ""
    }
    @objc private func pp1Tapped() { link.setValue(0xD23F, 1) }
    @objc private func slogTapped() {
        if let s = link.slog3Slot { link.setValue(0xD23F, s) } else { link.scanSlots() }
    }
    @objc private func scanTapped() { link.scanSlots() }
    @objc private func ppPicked() {
        guard let n = ppPopup.selectedItem?.representedObject as? NSNumber else { return }
        link.setValue(0xD23F, n.uint64Value)
    }
    @objc private func recTapped() { link.toggleRec() }
    @objc private func aelTapped() { link.press(0xD2C3, name: "AEL") }
    @objc private func felTapped() { link.press(0xD2C9, name: "FEL") }
    @objc private func awblTapped() { link.press(0xD2D9, name: "AWBL") }
}
