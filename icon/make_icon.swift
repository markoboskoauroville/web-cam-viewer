// The icon (swift-apps.md: it shows what the app IS): a webcam on a dark tile, its lens looking out, the camera menu's
// chevron bar above it, and the version under it (version-visible.md). Usage: swift make_icon.swift <version> <out.png>
import AppKit
let a = CommandLine.arguments
let version = a.count > 1 ? a[1] : "1", out = a.count > 2 ? a[2] : "icon_1024.png"
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func c(_ v: UInt32, _ al: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: al)
}
func grad(_ r: CGRect, _ top: UInt32, _ bottom: UInt32) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(top).cgColor, c(bottom).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
}
// the tile
ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 180, cornerHeight: 180, transform: nil))
ctx.setFillColor(c(0x1F1F20).cgColor); ctx.fillPath()
// the menu bar at the top: a pill with a chevron
let pill = CGRect(x: 250, y: 760, width: 524, height: 92)
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 46, cornerHeight: 46, transform: nil)); ctx.setFillColor(c(0x3A3A3D).cgColor); ctx.fillPath()
ctx.setFillColor(c(0x8E8E93).cgColor)
ctx.fill(CGRect(x: 300, y: 796, width: 280, height: 20))
ctx.move(to: CGPoint(x: 660, y: 822)); ctx.addLine(to: CGPoint(x: 690, y: 792)); ctx.addLine(to: CGPoint(x: 720, y: 822))
ctx.setStrokeColor(c(0xC8CDD2).cgColor); ctx.setLineWidth(14); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
// the stand
ctx.setFillColor(c(0x48484A).cgColor)
ctx.fill(CGRect(x: 487, y: 300, width: 50, height: 110))
ctx.addPath(CGPath(roundedRect: CGRect(x: 360, y: 280, width: 304, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.fillPath()
// the camera body
let body = CGRect(x: 312, y: 380, width: 400, height: 360)
let bp = CGPath(roundedRect: body, cornerWidth: 180, cornerHeight: 180, transform: nil)
ctx.saveGState(); ctx.addPath(bp); ctx.clip(); grad(body, 0x5A5A5E, 0x2C2C2E); ctx.restoreGState()
ctx.addPath(bp); ctx.setStrokeColor(c(0xFFFFFF, 0.22).cgColor); ctx.setLineWidth(6); ctx.strokePath()
// the lens: rings, glass, a highlight
let cx: CGFloat = 512, cy: CGFloat = 560
for (r, col) in [(130, 0x111113), (104, 0x1C3D5A), (66, 0x0A1622)] as [(CGFloat, UInt32)] {
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)); ctx.setFillColor(c(col).cgColor); ctx.fillPath()
}
ctx.addEllipse(in: CGRect(x: cx - 130, y: cy - 130, width: 260, height: 260)); ctx.setStrokeColor(c(0x8E8E93, 0.6).cgColor); ctx.setLineWidth(8); ctx.strokePath()
ctx.addEllipse(in: CGRect(x: cx + 14, y: cy + 26, width: 38, height: 38)); ctx.setFillColor(c(0xFFFFFF, 0.75).cgColor); ctx.fillPath()
// the green light
ctx.addEllipse(in: CGRect(x: 498, y: 700, width: 28, height: 28)); ctx.setFillColor(c(0x34C759).cgColor); ctx.fillPath()
// the version
let v = NSAttributedString(string: "v" + version, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 96, weight: .bold), .foregroundColor: c(0xC8CDD2)])
let vs = v.size(); v.draw(at: NSPoint(x: S / 2 - vs.width / 2, y: 150))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
