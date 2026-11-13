import AppKit

// v7, Marko 13.11.2026: "when it's in a full screen or any screen, when I click on the image, I want to see a choice of the
// camera and a choice of the sound." A see-through layer over the picture (under the top bar, which stays): two lists of
// blobs, CAMERA (each camera, then its "· vertical slice") and SOUND (every input, then No sound), the current one marked.
// A click on a blob picks it; a click outside the lists or Esc closes. Look after the classroom page's menu, simpler.
final class ChoiceOverlay: NSView {
    struct Row { let title: String; let current: Bool; let action: () -> Void }
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        isHidden = true
        setAccessibilityIdentifier("choice-overlay")
    }
    required init?(coder: NSCoder) { fatalError() }

    private var panel: NSStackView?

    func show(cameras: [Row], sounds: [Row]) {
        panel?.removeFromSuperview()
        let p = NSStackView(views: [column("CAMERA", cameras), column("SOUND", sounds)])
        p.orientation = .horizontal; p.alignment = .top; p.spacing = 32
        p.translatesAutoresizingMaskIntoConstraints = false
        addSubview(p)
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: centerXAnchor),
            p.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 10),
            p.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            p.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        panel = p
        isHidden = false
    }

    func close() { isHidden = true; panel?.removeFromSuperview(); panel = nil; onClose?() }

    private func column(_ head: String, _ rows: [Row]) -> NSStackView {
        let h = NSTextField(labelWithString: head)
        h.font = .systemFont(ofSize: 11, weight: .semibold)
        h.textColor = NSColor.white.withAlphaComponent(0.6)
        var views: [NSView] = [h]
        for r in rows { views.append(Blob(r) { [weak self] in r.action(); self?.close() }) }
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .width; s.spacing = 6
        s.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        s.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
        return s
    }

    // a click on the dim area (not on a blob) closes
    override func mouseDown(with event: NSEvent) { close() }
    override var acceptsFirstResponder: Bool { true }
}

private final class Blob: NSButton {
    private let run: () -> Void
    init(_ row: ChoiceOverlay.Row, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = (row.current ? NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 0.45)
                                              : NSColor.white.withAlphaComponent(0.14)).cgColor
        alignment = .left
        let st = NSMutableParagraphStyle(); st.alignment = .left; st.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: (row.current ? "✓  " : "    ") + row.title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: row.current ? .semibold : .regular), .paragraphStyle: st])
        target = self; action = #selector(go)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        setAccessibilityLabel(row.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func go() { run() }
}
