// DMG window background 660x400 @2x: dark grid, faint halo ring, "drag to Applications" arrow.
import Cocoa
let W: CGFloat = 660, H: CGFloat = 400, scale: CGFloat = 2
let img = NSImage(size: NSSize(width: W, height: H))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*scale), pixelsHigh: Int(H*scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(srgbRed: 0.09, green: 0.09, blue: 0.14, alpha: 1), CGColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05))
var y: CGFloat = 14; while y < H { var x: CGFloat = 14; while x < W { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 2, height: 2)); x += 26 }; y += 26 }
// faint colour wash behind the icons
for (cx, col) in [(CGFloat(165), CGColor(srgbRed: 1, green: 0.45, blue: 0.3, alpha: 0.18)), (CGFloat(495), CGColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 0.14))] {
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 90, color: col); ctx.setFillColor(col)
    ctx.fillEllipse(in: CGRect(x: cx - 70, y: 130, width: 140, height: 140)); ctx.restoreGState()
}
// arrow
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: 200)); ctx.addLine(to: CGPoint(x: 392, y: 200)); ctx.strokePath()
ctx.move(to: CGPoint(x: 372, y: 216)); ctx.addLine(to: CGPoint(x: 394, y: 200)); ctx.addLine(to: CGPoint(x: 372, y: 184)); ctx.strokePath()
// text
let para = NSMutableParagraphStyle(); para.alignment = .center
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, _ yy: CGFloat, mono: Bool = false) {
    let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    (s as NSString).draw(in: NSRect(x: 0, y: yy, width: W, height: size + 10), withAttributes: [.font: f, .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: para])
}
text("HALO", 30, .black, 0.95, 318)
text("agent halos · arrow connectors · workspace deck", 12.5, .medium, 0.55, 296)
text("drag Halo into Applications, then launch it once", 11, .regular, 0.55, 72, mono: true)
text("it installs the  halo  command and opens the deck", 11, .regular, 0.45, 54, mono: true)
text("github.com/mightbeanshuu/halo", 10.5, .semibold, 0.35, 28, mono: true)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "assets/dmg-background.png"))
print("bg ok")
