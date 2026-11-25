// SonyPanel.swift (v21, tabs since v39): the SONY overlay. A see-through layer over the live picture, under the top bar (never over it),
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
    let tabTag = NSButton(title: "", target: nil, action: nil)     // v39: in a search result, the tab it lives in
    var onPick: ((UInt64) -> Void)?
    var onTag: (() -> Void)?
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
        for v in [name, popup, minus, plus, value, tabTag] { addSubview(v) }
        tabTag.isBordered = false; tabTag.isHidden = true
        tabTag.font = .systemFont(ofSize: 9, weight: .bold)
        tabTag.target = self; tabTag.action = #selector(tagTapped)
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
        var tw: CGFloat = 0
        if !tabTag.isHidden { tabTag.sizeToFit(); tw = tabTag.frame.width + 4; tabTag.frame = NSRect(x: bounds.width - 6 - tabTag.frame.width, y: 3, width: tabTag.frame.width, height: 14) }
        name.frame = NSRect(x: 8, y: 4, width: w - tw, height: 26)
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

    /// v39: "EXPOSURE" in the corner of a search result; nil hides it
    func showTag(_ t: SonyTab?) {
        tabTag.isHidden = t == nil
        if let t {
            tabTag.attributedTitle = NSAttributedString(string: t.title, attributes: [.foregroundColor: NSColor.systemTeal, .font: tabTag.font!])
            tabTag.setAccessibilityLabel("Go to \(t.title)")
            tabTag.toolTip = "This setting lives in \(t.title): click to open that tab"
        }
        needsLayout = true
    }
    @objc private func tagTapped() { onTag?() }
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

// MARK: v39, the tabs. Marko 25.11.2026: "all the settings should be in the tabs, in different tabs. So they're organized by
// tabs." Each setting the camera reports goes to one tab: by its code where it is known, else by the words of its name.
// Only what the camera reports is shown; nothing is invented.
enum SonyTab: String, CaseIterable {
    case connect, exposure, focus, movie, media, camera
    var title: String {
        switch self {
        case .connect: return "CONNECT"
        case .exposure: return "EXPOSURE"
        case .focus: return "FOCUS"
        case .movie: return "MOVIE"
        case .media: return "SOUND/MEDIA"
        case .camera: return "CAMERA"
        }
    }
    static var saved: SonyTab {
        get { SonyTab(rawValue: UserDefaults.standard.string(forKey: "sony.tab") ?? "") ?? .connect }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sony.tab") }
    }
    /// "connect", "CONNECT", "sound", "SOUND/MEDIA", "media" → the tab
    static func named(_ s: String) -> SonyTab? {
        let k = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let t = SonyTab(rawValue: k) { return t }
        if k.hasPrefix("sound") || k.contains("media") { return .media }
        return allCases.first { $0.title.lowercased() == k }
    }

    private static let byCode: [UInt16: SonyTab] = [
        0x500E: .exposure, 0xD20D: .exposure, 0x5007: .exposure, 0xD21E: .exposure, 0x5010: .exposure, 0x500B: .exposure,
        0x500C: .exposure, 0xD200: .exposure, 0xD201: .exposure, 0xD099: .exposure, 0xD173: .exposure, 0x5013: .exposure,
        0xD203: .exposure, 0xD288: .media, 0xD211: .exposure,
        0x500A: .focus, 0xD22C: .focus, 0xD007: .focus, 0xD213: .focus, 0xD24C: .focus,
        0x5005: .movie, 0xD20F: .movie, 0xD23F: .movie, 0xD21D: .movie, 0xD0FA: .movie, 0xD253: .movie, 0xD241: .movie,
        0xD242: .movie, 0xD0E1: .movie, 0xD0E9: .movie, 0xE000: .movie, 0xE001: .movie,
        0xD218: .camera, 0xD204: .camera, 0xD205: .camera, 0xD20E: .camera, 0xD12D: .camera, 0xD12E: .camera,
        0xD0DD: .camera, 0xD0DE: .camera, 0xD1B3: .camera, 0xD0DB: .camera, 0xD040: .camera, 0xD07B: .camera,
        0xD24A: .media, 0xD248: .media, 0xD249: .media]

    private static var known: [UInt16: SonyTab] = [:]     // main thread: a code's tab never changes
    static func of(_ code: UInt16) -> SonyTab {
        if let t = byCode[code] { return t }
        if let t = known[code] { return t }
        let t = classify(code); known[code] = t; return t
    }
    private static func classify(_ code: UInt16) -> SonyTab {
        let n = " " + SonyLabels.name(code).lowercased() + " "
        func has(_ w: [String]) -> Bool { w.contains { n.contains($0) } }
        if has(["audio", "wind noise", "noise cut", " mic", "volume"]) { return .media }
        if has(["hdmi", "usb", "monitor", "display", "finder", "power", "battery", "firmware", "software", "lens model",
                "lens version", "date/time", "key lock", "grid", "debug", "silent", "operating mode", "error"]) { return .camera }
        if has(["media", "slot", "ftp", "file number", "folder", "file type", "save destination", "trans size", "copyright",
                "photographer", "iptc", "proxy", "contentinfo", "playback", "remote save", "image id", "file name",
                "file format (still", "raw"]) { return .media }
        if has(["focus", " af ", " af-", " af)", "(af", "subject recognition", "recognition", " eye", "face/eye", "tracking",
                "touch", "near/far"]) { return .focus }
        if has(["movie", "picture profile", "creative look", "custom look", "baselook", "gamma", "color", "white balance",
                " wb ", "awb", "biaxial", "steady shot", "stabiliz", "time code", "user bit", "tc/ub", "eframing", "s&q",
                " lut", "shutter angle", "log", "hlg", "soft skin"]) { return .movie }
        if has(["exposure", "f-number", "t-number", "iso", "shutter speed", "shutter type", "shutter mode", "metering",
                "flash", "iris", " nd ", "bracket", "dro", "program", "continuous shooting", "contshoot", "still capture",
                "gain", "slow shutter", " nr ", "nr)", "flicker", "self timer", "self-timer", "timeshift", "interval rec (still",
                "e-front curtain", "aspect", "image size", "zoom"]) { return .exposure }
        return .camera
    }

    /// the settings the Mac may set (GetSet 1) in this tab, the ones Marko named first, then the catalogue order
    static func cards(_ t: SonyTab, _ props: [UInt16: SonyProp]) -> [UInt16] {
        guard t != .connect else { return [] }
        let mine = props.values.filter { $0.getSet == 1 && !SonyPanel.skip.contains($0.code) && of($0.code) == t }.map(\.code)
        let first = SonyPanel.main.filter { mine.contains($0) }
        let rest = mine.filter { !first.contains($0) }
            .sorted { (SonyLabels.order[$0] ?? 99_999, $0) < (SonyLabels.order[$1] ?? 99_999, $1) }
        return first + rest
    }

    /// read-only facts shown as text in a tab (what the camera reports about itself, its cards and its power)
    private static let factCodes: [SonyTab: [UInt16]] = [
        .camera: [0xD040, 0xD07B, 0xD07D, 0xD218, 0xD204, 0xD205, 0xD12E, 0xD0BC, 0xD223, 0xD181, 0xD079, 0xD187,
                  0xD1BB, 0xD1BC, 0xD195, 0xD194],
        .media: [0xD248, 0xD249, 0xD24A, 0xD197, 0xD198, 0xD042, 0xD241, 0xD242],
        .movie: [0xD21D, 0xD241, 0xD242, 0xD0D5, 0xD0D9],
        .exposure: [0x500E, 0xD20D, 0xD217, 0xD21F, 0xD1B5, 0xD1BF],
        .focus: [0xD213, 0xD24C, 0xD19C]]
    static func facts(_ t: SonyTab, _ props: [UInt16: SonyProp]) -> [UInt16] {
        var out = (factCodes[t] ?? []).filter { props[$0] != nil && props[$0]!.getSet == 0 }
        if t == .media {   // every card slot fact the camera reports (SLOT2 too)
            let slots = props.values.filter { $0.getSet == 0 && SonyLabels.name($0.code).uppercased().contains("SLOT") }.map(\.code).sorted()
            for c in slots where !out.contains(c) { out.append(c) }
        }
        return out
    }
    // MARK: v39, SEARCH SETTINGS. Marko: "Also, search engine for settings so I can filter settings and get the right
    // settings on the screen." Every word must match the setting's name, its current value, its tab, or a synonym (word
    // starts and substrings, any case). Only the cached property list is read: the camera is never asked per keystroke.
    static let synonyms: [String: [String]] = [
        "speed": ["shutter speed", "shutter"], "shutter": ["shutter speed"], "wb": ["white balance", "awb"],
        "white": ["white balance"], "kelvin": ["color temperature"], "temp": ["color temperature", "temperature"],
        "rec": ["movie recording", "record", "rec "], "record": ["rec", "movie recording"], "battery": ["battery", "power"],
        "format": ["file format", "format", "recording setting"], "profile": ["picture profile"], "pp": ["picture profile"],
        "log": ["gamma", "picture profile", "s-log", "slog"], "ev": ["exposure bias", "exposure compensation"],
        "compensation": ["exposure bias"], "aperture": ["f-number", "iris"], "iris": ["f-number"], "f": ["f-number"],
        "fnumber": ["f-number"], "af": ["focus", " af"], "mf": ["focus mode", "manual"], "fps": ["frame rate"],
        "framerate": ["frame rate"], "sound": ["audio"], "mic": ["audio", "mic"], "audio": ["audio", "wind noise"],
        "card": ["media", "slot"], "sd": ["media", "slot"], "stab": ["stabiliz", "steady shot"], "ibis": ["steady shot", "stabiliz"],
        "steady": ["steady shot"], "tc": ["time code"], "timecode": ["time code"], "gain": ["iso", "gain"],
        "sensitivity": ["iso"], "metering": ["metering"], "meter": ["metering"], "lut": ["lut", "baselook"],
        "look": ["creative look", "baselook"], "display": ["monitor", "display", "finder"], "screen": ["monitor", "display"],
        "hdmi": ["hdmi"], "usb": ["usb"], "wifi": ["wi-fi", "ftp"], "nd": ["nd "], "eye": ["eye", "recognition"],
        "face": ["face", "recognition"], "dro": ["dynamic range"], "hdr": ["hdr", "hlg"], "quality": ["quality", "recording setting"]]

    /// every word of the query matches this setting (name, current value, tab title, or a synonym of the word)
    static func matches(_ c: UInt16, _ p: SonyProp, _ words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let hay = " " + [SonyLabels.name(c), p.string ?? SonyLabels.label(c, p.value, type: p.type), of(c).title, sonyHex(c)]
            .joined(separator: " ").lowercased() + " "
        return words.allSatisfy { w in
            if hay.contains(w) { return true }
            return (synonyms[w] ?? []).contains { hay.contains($0) }
        }
    }
    static func words(_ q: String) -> [String] {
        q.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { !$0.isEmpty }
    }
    /// (settable settings, read-only facts) matching the query, across every tab
    static func search(_ q: String, _ props: [UInt16: SonyProp]) -> (cards: [UInt16], facts: [UInt16]) {
        let w = words(q)
        guard !w.isEmpty else { return ([], []) }
        let order: (UInt16, UInt16) -> Bool = { a, b in
            let ta = allCases.firstIndex(of: of(a)) ?? 9, tb = allCases.firstIndex(of: of(b)) ?? 9
            return (ta, SonyPanel.main.firstIndex(of: a) ?? 999, SonyLabels.order[a] ?? 99_999, a) <
                   (tb, SonyPanel.main.firstIndex(of: b) ?? 999, SonyLabels.order[b] ?? 99_999, b)
        }
        let hits = props.values.filter { matches($0.code, $0, w) }
        let cards = hits.filter { $0.getSet == 1 && !SonyPanel.skip.contains($0.code) }.map(\.code).sorted(by: order)
        let facts = hits.filter { $0.getSet == 0 || SonyPanel.skip.contains($0.code) }.map(\.code).sorted(by: order)
        return (cards, facts)
    }
    /// the camera buttons and the CONNECT row match words too ("rec", "profile", "scan")
    static func buttonsMatch(_ words: [String], _ hay: String) -> Bool {
        !words.isEmpty && words.allSatisfy { w in hay.contains(w) || (synonyms[w] ?? []).contains { hay.contains($0) } }
    }

    /// "Software Version: 2.00"
    static func factLine(_ c: UInt16, _ p: SonyProp) -> String {
        var v = p.string ?? SonyLabels.label(c, p.value, type: p.type)
        if v.isEmpty { v = "—" }
        return "\(SonyLabels.name(c)): \(v)"
    }
}

final class SonyPanel: NSView {
    let link: SonyLink
    var onClose: (() -> Void)?
    private let scroll = NSScrollView()
    private let doc = FlowDoc()
    private let head = FlowDoc()                  // v39: the title, the tabs and the facts stay put; the tab scrolls

    // header
    private let title = label("SONY", size: 13, weight: .bold)
    private let closeKey = NSButton(title: "HIDE", target: nil, action: nil)
    private let search = NSSearchField(string: "")       // v39: SEARCH SETTINGS, above the tabs (not kept between launches)
    private let searchNote = label("", size: 11, color: white.withAlphaComponent(0.7))
    private var query: String { search.stringValue.trimmingCharacters(in: .whitespaces) }
    private var tagged: Set<UInt16> = []
    private var tabKeys: [SonyTab: NSButton] = [:]
    private(set) var tab: SonyTab = SonyTab.saved
    private let facts = label("", size: 12, color: white.withAlphaComponent(0.85), lines: 2)
    // CONNECT
    private let status = label("", size: 12, color: white.withAlphaComponent(0.85), lines: 0)
    private let stages = label("", size: 11, color: white.withAlphaComponent(0.75), lines: 0)
    private let takeKey = NSButton(title: "TAKE CONTROL (closes Imaging Edge Remote)", target: nil, action: nil)
    private let checkKey = NSButton(title: "CHECK", target: nil, action: nil)
    private let connectKey = NSButton(title: "CONNECT", target: nil, action: nil)
    private let address = NSTextField(string: "")
    private let scanKey = NSButton(title: "SCAN", target: nil, action: nil)
    private let found = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scanLine = label("", size: 12, weight: .semibold, color: white.withAlphaComponent(0.9), lines: 0)
    private let scanLines = label("", size: 11, color: white.withAlphaComponent(0.7), lines: 0)
    private let roadHead = label("ROAD", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private var roadKeys: [(String, NSButton)] = []
    private let demoKey = NSButton(title: "DEMO", target: nil, action: nil)
    // login (Access Authentication)
    private let finger = label("", size: 11, color: white.withAlphaComponent(0.85), lines: 4)
    private let userField = NSTextField(string: "")
    private let passField = NSSecureTextField(string: "")
    private let loginKey = NSButton(title: "SAME AS CAMERA · CONNECT", target: nil, action: nil)
    // MOVIE: picture profile and REC
    private let ppHead = label("PICTURE PROFILE", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private let pp1Key = NSButton(title: "PP1", target: nil, action: nil)
    private let slogKey = NSButton(title: "S-LOG3", target: nil, action: nil)
    private let ppPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let slotsKey = NSButton(title: "READ SLOTS", target: nil, action: nil)
    private let keysHead = label("CAMERA BUTTONS", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private let recKey = NSButton(title: "● REC", target: nil, action: nil)
    private let aelKey = NSButton(title: "AEL", target: nil, action: nil)
    private let felKey = NSButton(title: "FEL", target: nil, action: nil)
    private let awblKey = NSButton(title: "AWBL", target: nil, action: nil)
    // the tab's settings and facts
    private let cardsHead = label("SETTINGS", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private let factsHead = label("WHAT THE CAMERA REPORTS", size: 11, weight: .semibold, color: white.withAlphaComponent(0.6))
    private let factText = label("", size: 12, color: white.withAlphaComponent(0.85), lines: 0)
    private let empty = label("", size: 12, color: white.withAlphaComponent(0.7), lines: 0)
    private var cards: [UInt16: Card] = [:]
    private var tabCodes: [UInt16] = []
    private var ppShown: [UInt64] = []
    private var foundShown: [String] = []
    private var headHeight: CGFloat = 80

    /// the settings Marko named first, in this order (when the camera reports them)
    static let main: [UInt16] = [0x500E, 0xD20D, 0x5007, 0xD21E, 0x5010, 0x5005, 0xD20F, 0xD201, 0x500B, 0x500A, 0xD22C,
                                 0xD253, 0xD203, 0xD288, 0xD287, 0xD0FA, 0xD0E1, 0xD0E9, 0xD25A]
    /// shown as facts or buttons, not as cards
    static let skip: Set<UInt16> = [0xD23F, 0xD21D, 0xD217, 0xD21F, 0xD24E, 0xD218, 0xD24A]

    override var isFlipped: Bool { true }

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
        addSubview(scroll)
        addSubview(head)

        func key(_ b: NSButton, _ sel: Selector, _ id: String, _ tip: String, big: Bool = false, in parent: NSView? = nil) {
            b.bezelStyle = .rounded
            b.controlSize = big ? .large : .regular
            if big { b.font = .systemFont(ofSize: 15, weight: .bold) } else { b.font = .systemFont(ofSize: 12, weight: .semibold) }
            b.target = self; b.action = sel
            b.setAccessibilityIdentifier(id); b.toolTip = tip
            (parent ?? doc).addSubview(b)
        }
        key(closeKey, #selector(hideTapped), "sony-hide", "Hide the Sony controls (SONY key or Escape)", in: head)
        search.placeholderString = "Search settings (iso, shutter, wb, rec, battery, format, profile, focus, ev …)"
        search.setAccessibilityLabel("SEARCH SETTINGS"); search.setAccessibilityTitle("SEARCH SETTINGS")
        search.setAccessibilityIdentifier("sony-search")
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.target = self; search.action = #selector(searchChanged)
        search.toolTip = "Filters every tab at once by name, value and synonyms; Escape or ✕ clears it"
        head.addSubview(search); head.addSubview(searchNote)
        for t in SonyTab.allCases {
            let b = NSButton(title: t.title, target: nil, action: nil)
            key(b, #selector(tabTapped(_:)), "sony-tab-\(t.rawValue)", "Show the \(t.title) settings", in: head)
            b.setAccessibilityLabel(t.title)
            b.identifier = NSUserInterfaceItemIdentifier(t.rawValue)
            tabKeys[t] = b
        }
        key(connectKey, #selector(connectTapped), "sony-connect", "Connect to the camera (Wi-Fi at the address, else the USB cable), or disconnect")
        key(scanKey, #selector(scanTapped), "sony-scan", "Find the Sony by itself: SSDP, an ARP sweep of this network with Sony's MAC prefixes, a real PTP/IP handshake, and the USB cable")
        scanKey.setAccessibilityLabel("SCAN")
        key(takeKey, #selector(takeTapped), "sony-takecontrol", "Imaging Edge Remote holds the camera's USB connection: close it and control the camera from this window")
        key(checkKey, #selector(checkTapped), "sony-check", "Check every stage again: the Mac's network, the camera's address, SSDP, the remote ports, the USB cable")
        key(demoKey, #selector(demoTapped), "sony-demo", "A pretend camera: shows every control without touching the Sony")
        key(loginKey, #selector(loginTapped), "sony-login", "The fingerprint above is the same as on the camera's Access Authen. Info: save it, the user and password, and connect")
        for (r, t, tip) in [("auto", "AUTO", "CONNECT tries Wi-Fi first, then the USB cable"), ("wifi", "WI-FI", "CONNECT uses only the network"),
                            ("usb", "USB", "CONNECT uses only the USB cable")] {
            let b = NSButton(title: t, target: nil, action: nil)
            key(b, #selector(roadTapped(_:)), "sony-road-\(r)", tip)
            b.identifier = NSUserInterfaceItemIdentifier(r)
            b.setAccessibilityLabel(t)
            roadKeys.append((r, b))
        }
        key(pp1Key, #selector(pp1Tapped), "sony-pp1", "Picture Profile 1 (shooting)", big: true)
        key(slogKey, #selector(slogTapped), "sony-slog3", "The Picture Profile slot the camera reports as S-Log3 with S-Gamut3.Cine", big: true)
        key(slotsKey, #selector(slotsTapped), "sony-readslots", "Select each Picture Profile slot in turn to read its gamma and color mode, then put back the one selected now")
        key(recKey, #selector(recTapped), "sony-rec", "Start or stop recording on the camera's card (answered by the camera's own REC state)", big: true)
        key(aelKey, #selector(aelTapped), "sony-ael", "AEL button (AE lock)")
        key(felKey, #selector(felTapped), "sony-fel", "FEL button (flash exposure lock)")
        key(awblKey, #selector(awblTapped), "sony-awbl", "AWBL button (auto white balance lock)")
        for b in [pp1Key, slogKey, recKey] { b.setContentHuggingPriority(.required, for: .horizontal) }

        ppPopup.target = self; ppPopup.action = #selector(ppPicked)
        ppPopup.setAccessibilityLabel("Picture Profile"); ppPopup.setAccessibilityIdentifier("sony-D23F")
        ppPopup.font = .systemFont(ofSize: 13)
        doc.addSubview(ppPopup)
        found.target = self; found.action = #selector(foundPicked)
        found.setAccessibilityLabel("Cameras found"); found.setAccessibilityIdentifier("sony-found")
        found.font = .systemFont(ofSize: 12)
        found.toolTip = "Every camera SCAN found: choose one to use its address"
        doc.addSubview(found)

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
        scanLines.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scanLines.setAccessibilityIdentifier("sony-scan-lines")
        scanLine.setAccessibilityIdentifier("sony-scan-stage")
        factText.setAccessibilityIdentifier("sony-facts")
        head.addSubview(title); head.addSubview(facts)
        for v in [status, stages, address, scanLine, scanLines, roadHead, finger, userField, passField, ppHead, keysHead,
                  cardsHead, factsHead, factText, empty] { doc.addSubview(v) }
        title.setAccessibilityLabel("Sony")
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    // a click on the dim area does nothing (no accidental close); the window still moves by its background
    override func mouseDown(with event: NSEvent) {}

    /// v39: a tab by the API (POST /sony/tab) or a key
    func select(_ t: SonyTab) {
        tab = t; SonyTab.saved = t
        if !query.isEmpty { search.stringValue = "" }
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        update()
    }

    /// v39: the search text (POST /sony/tab {search}); "" goes back to the tabs
    func setSearch(_ q: String) { search.stringValue = q; searchChanged() }
    var searchText: String { query }
    /// Escape: a search is cleared first, the overlay hides only when there is none
    func clearSearch() -> Bool {
        guard !search.stringValue.isEmpty else { return false }
        search.stringValue = ""; searchChanged(); return true
    }
    @objc private func searchChanged() {
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        update()
    }

    // MARK: values from the camera
    func update() {
        let p = link.props
        let model = link.found?.model ?? (link.savedModel.isEmpty ? "α7 V" : link.savedModel)
        title.stringValue = "SONY  " + model
        for (t, b) in tabKeys {
            let n = SonyTab.cards(t, p).count
            b.toolTip = t == .connect ? "Address, SCAN, CONNECT, the road and every stage" : "\(t.title): \(n) settings the camera reports here"
            tint(b, on: t == tab && query.isEmpty, color: .systemTeal)
        }
        var f: [String] = []
        if let r = p[0xD21D] { f.append(r.value == 1 ? "● REC" : r.value == 3 ? "waiting" : r.value == 2 ? "REC failed" : "STBY") }
        if let b = p[0xD218], b.enabled != 0 { f.append("battery " + SonyLabels.label(0xD218, b.value)) }
        if let c = p[0xD24A], c.enabled != 0 { f.append("card " + SonyLabels.label(0xD24A, c.value)) }
        if link.connected { f.append("\(link.transport) · \(p.values.filter { $0.settable }.count) settable now") }
        else { f.append(link.phase == .connecting || link.phase == .searching ? "connecting…" : "not connected") }
        facts.stringValue = f.joined(separator: "   ·   ")

        // CONNECT
        var s = link.busy ?? link.message
        if s.isEmpty { s = "Not connected. SCAN finds the camera; CONNECT uses the address (or the cable); DEMO shows the controls without it." }
        if let last = link.log.last, last != s, link.connected { s += "\n" + last }
        status.stringValue = s
        let d = link.diagnosis
        stages.stringValue = d?.lines.joined(separator: "\n") ?? ""
        takeKey.isHidden = link.phase != .usbBusy
        if let n = d?.usb?.ownerName, !n.isEmpty, d?.usb?.heldByOther == true { takeKey.title = "TAKE CONTROL (closes \(n))" }
        checkKey.isHidden = link.connected || link.phase == .connecting || link.phase == .searching
        connectKey.title = link.connected || link.phase == .connecting || link.phase == .searching ? "DISCONNECT" : "CONNECT"
        demoKey.isHidden = link.connected && !link.demo
        demoKey.title = link.demo ? "DEMO ✓" : "DEMO"
        if address.currentEditor() == nil, address.stringValue != link.savedAddress { address.stringValue = link.savedAddress }
        let sc = link.scanner
        scanKey.isEnabled = sc.state != .running
        scanKey.title = sc.state == .running ? "SCAN…" : "SCAN"
        scanLine.stringValue = sc.state == .idle ? "" : sc.stage
        scanLines.stringValue = sc.state == .idle ? "" : sc.lines.dropLast(sc.state == .done ? 1 : 0).joined(separator: "\n")
        let titles = sc.candidates.map(\.title)
        if titles != foundShown {
            found.removeAllItems()
            for c in sc.candidates { found.addItem(withTitle: c.title); found.lastItem?.representedObject = c.address }
            foundShown = titles
        }
        let current = link.road == "usb" ? "USB" : link.savedAddress
        if let i = sc.candidates.firstIndex(where: { $0.address == current }) { found.selectItem(at: i) }
        found.isHidden = sc.candidates.isEmpty
        found.sizeToFit()
        for (r, b) in roadKeys { tint(b, on: link.road == r) }
        let login = link.phase == .needLogin
        for v in [finger, userField, passField, loginKey] as [NSView] { v.isHidden = !login }
        if login {
            let k = link.hostKey.map { "Camera fingerprint (compare with MENU → Network → Network Option → Access Authen. Info):\n" + $0.sha256.joined(separator: "\n") }
            finger.stringValue = k ?? "The fingerprint was approved before. Type the user and password from Access Authen. Info."
        }

        // MOVIE: picture profile
        let pp = p[0xD23F]
        let ppLive = pp?.settable ?? false
        let cur = pp?.value
        func slotTitle(_ s: UInt64) -> String {
            if let k = link.slots[s] { return "\(SonyLabels.ppShort(s)) · \(SonyLabels.gamma(k.gamma)) / \(SonyLabels.colorMode(k.color))" }
            return SonyLabels.ppShort(s)
        }
        pp1Key.title = link.slots[1].map { "PP1 · \(SonyLabels.gamma($0.gamma))" } ?? "PP1"
        if let s = link.slog3Slot { slogKey.title = "S-Log3 · S-Gamut3.Cine (\(SonyLabels.ppShort(s)))" } else { slogKey.title = "S-Log3: READ SLOTS first" }
        slogKey.isEnabled = ppLive && link.busy == nil
        pp1Key.isEnabled = ppLive && link.busy == nil && (pp?.options.contains(1) ?? false)
        tint(pp1Key, on: cur == 1)
        tint(slogKey, on: cur != nil && cur == link.slog3Slot)
        slotsKey.isEnabled = ppLive && link.busy == nil && !link.recording
        ppHead.stringValue = pp.map { "PICTURE PROFILE · \(SonyLabels.ppShort($0.value))" + ($0.settable ? "" : " (the camera does not allow a change now)") } ?? "PICTURE PROFILE"
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

        // buttons
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

        // the tab's cards and facts
        let hit = query.isEmpty ? nil : SonyTab.search(query, p)
        tabCodes = hit?.cards ?? SonyTab.cards(tab, p)
        let wanted = Set(tabCodes)
        for (c, card) in cards where !wanted.contains(c) { card.removeFromSuperview(); cards[c] = nil }
        for c in tabCodes {
            let card: Card
            if let k = cards[c] { card = k } else {
                card = Card(code: c)
                card.onPick = { [weak self] v in self?.link.setValue(c, v) }
                doc.addSubview(card); cards[c] = card
            }
            if let prop = p[c] { card.update(prop) }
            if hit != nil {
                let t = SonyTab.of(c)
                card.showTag(t)
                card.onTag = { [weak self] in self?.select(t) }
            } else if tagged.contains(c) { card.showTag(nil) }
        }
        tagged = hit != nil ? wanted : []
        let fc = hit?.facts ?? SonyTab.facts(tab, p)
        var lines = fc.compactMap { c in p[c].map { SonyTab.factLine(c, $0) + (hit != nil ? "  (\(SonyTab.of(c).title))" : "") } }
        if hit != nil {
            let n = tabCodes.count + lines.count
            searchNote.stringValue = p.isEmpty ? "Not connected: nothing to search yet (CONNECT or DEMO first)"
                : n == 0 ? "Nothing matches “\(query)” among the \(p.count) settings the camera reports"
                : "\(tabCodes.count) settings and \(lines.count) facts match “\(query)” (across every tab; empty search = back to the tabs)"
        } else { searchNote.stringValue = "" }
        if hit == nil && tab == .camera {
            var top: [String] = ["Model: \(model)"]
            if !link.transport.isEmpty { top.append("Connected over: \(link.transport)") }
            if let u = d?.usb { top.append("USB: \(u.product) (0x054C:\(String(format: "0x%04X", u.productID)))" + (u.heldByOther ? ", held by \(u.ownerName)" : "")) }
            lines = top + lines
        }
        factText.stringValue = lines.joined(separator: "\n")
        factsHead.stringValue = hit != nil ? "MATCHING FACTS THE CAMERA REPORTS" : "WHAT THE CAMERA REPORTS"
        cardsHead.stringValue = hit != nil ? "MATCHING SETTINGS (\(tabCodes.count); the corner says the tab, click it to go there)" : "SETTINGS THE MAC CAN CHANGE (\(tabCodes.count); grey = the camera does not allow it now)"
        empty.stringValue = hit == nil && tab != .connect && p.isEmpty ? "Not connected: the camera's \(tab.title) settings appear here once CONNECT (or DEMO) is on." : ""
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

    // MARK: layout: the head (title, tabs, facts), then the tab in rows that wrap with the width and scroll
    override func layout() {
        super.layout()
        let width = max(260, bounds.width)
        let m: CGFloat = 16, gap: CGFloat = 8
        var y: CGFloat = 10
        func fit(_ v: NSView, _ w: CGFloat) -> NSSize {
            if let c = v as? NSControl { c.sizeToFit() }
            var s = v.fittingSize
            if v === address || v === userField || v === passField { s = NSSize(width: 200, height: 24) }
            if v === found { s.width = min(max(s.width, 180), w - 2 * m) }
            return NSSize(width: min(s.width, w - 2 * m), height: max(s.height, 22))
        }
        func row(_ items: [NSView], _ w: CGFloat, spacing: CGFloat = gap) {
            var x = m, h: CGFloat = 0
            for v in items where !v.isHidden {
                let s = fit(v, w)
                if x > m && x + s.width > w - m { x = m; y += h + spacing; h = 0 }
                v.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
                x += s.width + spacing; h = max(h, s.height)
            }
            if h > 0 { y += h + 10 }
        }
        func text(_ l: NSTextField, _ w: CGFloat) {
            guard !l.isHidden, !l.stringValue.isEmpty else { l.frame = .zero; return }
            l.preferredMaxLayoutWidth = w - 2 * m
            let h = l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w - 2 * m, height: 4000)).height ?? 18
            l.frame = NSRect(x: m, y: y, width: w - 2 * m, height: ceil(h))
            y += ceil(h) + 8
        }
        // the head
        row([title, closeKey], width)
        search.frame = NSRect(x: m, y: y, width: max(120, min(width - 2 * m, 460)), height: 24); y += 30
        text(searchNote, width)
        row(SonyTab.allCases.compactMap { tabKeys[$0] }, width, spacing: 6)
        text(facts, width)
        headHeight = y
        head.frame = NSRect(x: 0, y: 0, width: width, height: headHeight)
        scroll.frame = NSRect(x: 0, y: headHeight, width: width, height: max(40, bounds.height - headHeight))

        // the tab
        let w = max(260, scroll.contentSize.width)
        y = 6
        let connectViews: [NSView] = [address, scanKey, found, connectKey, demoKey, scanLine, scanLines, roadHead, status,
                                      takeKey, checkKey, stages, finger, userField, passField, loginKey] + roadKeys.map { $0.1 }
        let movieViews: [NSView] = [ppHead, pp1Key, slogKey, ppPopup, slotsKey, recKey, awblKey]
        let exposureViews: [NSView] = [aelKey, felKey]
        let allTabViews = connectViews + movieViews + exposureViews + [keysHead, cardsHead, factsHead, factText, empty]
        let login = link.phase == .needLogin
        for v in allTabViews { v.isHidden = true }
        for (_, c) in cards { c.isHidden = true }
        func show(_ vs: [NSView]) { vs.forEach { $0.isHidden = false } }
        let words = SonyTab.words(query)
        let searching = !words.isEmpty
        switch searching ? nil : tab {
        case nil:
            // the results page: the camera buttons and the CONNECT row when the words name them, then the settings
            if SonyTab.buttonsMatch(words, "rec record movie recording ● rec stop") { show([recKey]); row([recKey], w) }
            if SonyTab.buttonsMatch(words, "picture profile pp1 s-log3 slog log slots gamma") {
                show([ppHead, pp1Key, slogKey, ppPopup, slotsKey]); text(ppHead, w); row([pp1Key, slogKey, ppPopup, slotsKey], w)
            }
            if SonyTab.buttonsMatch(words, "ael fel awbl lock exposure flash white balance") {
                show([aelKey, felKey, awblKey]); row([aelKey, felKey, awblKey], w)
            }
            if SonyTab.buttonsMatch(words, "scan connect address ip wi-fi wifi usb network camera road") {
                show([address, scanKey, connectKey]); found.isHidden = link.scanner.candidates.isEmpty
                row([address, scanKey, found, connectKey], w)
            }
        case .connect?:
            show([address, scanKey, connectKey, roadHead, status, stages, scanLine, scanLines] + roadKeys.map { $0.1 })
            found.isHidden = link.scanner.candidates.isEmpty
            demoKey.isHidden = link.connected && !link.demo
            takeKey.isHidden = link.phase != .usbBusy
            checkKey.isHidden = link.connected || link.phase == .connecting || link.phase == .searching
            row([address, scanKey, found, connectKey, demoKey], w)
            text(scanLine, w)
            text(scanLines, w)
            row([roadHead] + roadKeys.map { $0.1 }, w, spacing: 6)
            text(status, w)
            row([takeKey, checkKey], w)
            stages.isHidden = link.connected || link.diagnosis == nil
            text(stages, w)
            if login { show([finger, userField, passField, loginKey]); text(finger, w); row([userField, passField, loginKey], w) }
        case .movie?:
            show([keysHead, recKey, awblKey, ppHead, pp1Key, slogKey, ppPopup, slotsKey])
            text(keysHead, w); row([recKey, awblKey], w)
            text(ppHead, w); row([pp1Key, slogKey, ppPopup, slotsKey], w)
        case .exposure?:
            show([keysHead, aelKey, felKey])
            text(keysHead, w); row([aelKey, felKey], w)
        default: break
        }
        if searching || tab != .connect {
            empty.isHidden = empty.stringValue.isEmpty
            text(empty, w)
            if !factText.stringValue.isEmpty { show([factsHead, factText]); text(factsHead, w); text(factText, w) }
            if !tabCodes.isEmpty {
                show([cardsHead]); text(cardsHead, w)
                let cw = Card.size.width, ch = Card.size.height
                let cols = max(1, Int((w - 2 * m + gap) / (cw + gap)))
                let cwid = min(cw * 1.4, (w - 2 * m - CGFloat(cols - 1) * gap) / CGFloat(cols))
                for (i, c) in tabCodes.enumerated() {
                    guard let card = cards[c] else { continue }
                    card.isHidden = false
                    card.frame = NSRect(x: m + CGFloat(i % cols) * (cwid + gap), y: y + CGFloat(i / cols) * (ch + gap), width: cwid, height: ch)
                }
                y += CGFloat((tabCodes.count + cols - 1) / cols) * (ch + gap) + 6
            }
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 8, scroll.contentSize.height))
    }

    // MARK: actions
    @objc private func tabTapped(_ b: NSButton) {
        guard let raw = b.identifier?.rawValue, let t = SonyTab(rawValue: raw) else { return }
        select(t)
    }
    @objc private func connectTapped() {
        link.savedAddress = address.stringValue
        if link.connected || link.phase == .connecting || link.phase == .searching { link.disconnect() } else { link.findAndConnect() }
    }
    @objc private func scanTapped() {
        if address.stringValue != link.savedAddress { link.savedAddress = address.stringValue }
        link.scan()
    }
    @objc private func foundPicked() {
        guard let a = found.selectedItem?.representedObject as? String else { return }
        link.choose(a)
    }
    @objc private func roadTapped(_ b: NSButton) { if let r = b.identifier?.rawValue { link.road = r } }
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
    @objc private func slotsTapped() { link.scanSlots() }
    @objc private func ppPicked() {
        guard let n = ppPopup.selectedItem?.representedObject as? NSNumber else { return }
        link.setValue(0xD23F, n.uint64Value)
    }
    @objc private func recTapped() { link.toggleRec() }
    @objc private func aelTapped() { link.press(0xD2C3, name: "AEL") }
    @objc private func felTapped() { link.press(0xD2C9, name: "FEL") }
    @objc private func awblTapped() { link.press(0xD2D9, name: "AWBL") }
}
