import AppKit

// v4, Marko, 1.11.2026: the Sony α7 V in the bar, words only, pipes between:
//   REC | BAT 82% | AF | F2.8 | 1/50 | ISO 800 | ILCE-7M5
// REC starts and stops the camera's own recording (grey idle, red recording). AF is green when the camera has focus;
// a press holds a half-press (S1) until it turns green. The values are read from the camera and kept fresh.
// The group shows only while a Sony is connected (CAMERA language: colour is the state, no boxes).
final class SonyBar: NSStackView {
    let rec = SonyBar.key("REC", id: "sony-rec", tip: "Start / stop recording on the Sony")
    let battery = SonyBar.label("BAT —", id: "sony-battery", tip: "The Sony's battery")
    let focus = SonyBar.key("AF", id: "sony-af", tip: "Focus: green when the Sony has focus; press to focus")
    let aperture = SonyBar.label("F—", id: "sony-aperture", tip: "Aperture")
    let shutter = SonyBar.label("—", id: "sony-shutter", tip: "Shutter speed")
    let iso = SonyBar.label("ISO —", id: "sony-iso", tip: "ISO")
    let name = SonyBar.label("SONY", id: "sony-name", tip: "The camera")

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let white = NSColor.white
    static let grey = NSColor(white: 0.62, alpha: 1)
    static let green = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.6, alpha: 1)      // #34D399
    static let amber = NSColor(srgbRed: 0.91, green: 0.639, blue: 0.239, alpha: 1)     // #E8A33D
    static let red = NSColor(srgbRed: 1, green: 0.231, blue: 0.188, alpha: 1)          // #FF3B30

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        let items: [NSView] = [rec, battery, focus, aperture, shutter, iso, name]
        for (n, v) in items.enumerated() {
            if n > 0 { addArrangedSubview(Self.pipe()) }
            addArrangedSubview(v)
        }
        setRecording(false); setFocused(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func pipe() -> NSTextField {
        let p = NSTextField(labelWithString: "|")
        p.font = font; p.textColor = NSColor(white: 1, alpha: 0.35)
        return p
    }
    private static func label(_ s: String, id: String, tip: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = font; l.textColor = white; l.toolTip = tip
        l.setAccessibilityIdentifier(id)
        l.lineBreakMode = .byClipping
        return l
    }
    private static func key(_ s: String, id: String, tip: String) -> NSButton {
        let b = NSButton(title: s, target: nil, action: nil)
        b.isBordered = false; b.font = font; b.toolTip = tip
        b.setAccessibilityIdentifier(id)
        return b
    }
    private static func paint(_ b: NSButton, _ c: NSColor) {
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [.font: font, .foregroundColor: c])
    }

    func setRecording(_ on: Bool) { Self.paint(rec, on ? Self.red : Self.grey) }
    func setFocused(_ on: Bool) { Self.paint(focus, on ? Self.green : Self.white) }
    func setBattery(_ percent: Int?) {
        battery.stringValue = percent.map { "BAT \($0)%" } ?? "BAT —"
        battery.textColor = (percent ?? 100) <= 20 ? Self.amber : Self.white
    }
}

// The camera and sound menus show at most eight characters of the chosen name (Marko: "1, 2, 3, 4, 5, 6, 7, 8
// characters, and that's enough"); the open menu still lists the full names.
final class ShortPopUpCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let n = (String(title.string.prefix(8)) as NSString).length
        return super.drawTitle(title.attributedSubstring(from: NSRange(location: 0, length: min(n, title.length))),
                               withFrame: frame, in: controlView)
    }
}
