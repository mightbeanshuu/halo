// Renders the Halo app icon: dark glass tile, glowing conic-gradient ring, orbiting node dots, tiny status pill.
import Cocoa
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// macOS-style rounded tile with margin
let tile = CGRect(x: S*0.08, y: S*0.08, width: S*0.84, height: S*0.84)
let tilePath = CGPath(roundedRect: tile, cornerWidth: S*0.19, cornerHeight: S*0.19, transform: nil)
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 1), CGColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
// dot grid
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05))
var y = tile.minY + 40; while y < tile.maxY { var x = tile.minX + 40; while x < tile.maxX { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 6, height: 6)); x += 64 }; y += 64 }
ctx.restoreGState()
// ring (conic gradient) with glow
let c = CGPoint(x: S/2, y: S/2), R: CGFloat = S*0.27, W: CGFloat = S*0.075
let colors: [CGColor] = [
    CGColor(srgbRed: 1.0, green: 0.48, blue: 0.25, alpha: 1), CGColor(srgbRed: 1.0, green: 0.25, blue: 0.51, alpha: 1),
    CGColor(srgbRed: 0.63, green: 0.33, blue: 1.0, alpha: 1), CGColor(srgbRed: 0.25, green: 0.59, blue: 1.0, alpha: 1),
    CGColor(srgbRed: 0.25, green: 0.88, blue: 0.82, alpha: 1), CGColor(srgbRed: 1.0, green: 0.77, blue: 0.25, alpha: 1),
    CGColor(srgbRed: 1.0, green: 0.48, blue: 0.25, alpha: 1)]
func lerp(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let x = a.components!, y = b.components!
    return CGColor(srgbRed: x[0] + (y[0]-x[0])*t, green: x[1] + (y[1]-x[1])*t, blue: x[2] + (y[2]-x[2])*t, alpha: 1)
}
/// conic gradient ring drawn as many short arcs (CoreGraphics has no conic API)
func drawConicRing(_ r: CGFloat, _ w: CGFloat) {
    let n = 720
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n) * CGFloat(colors.count - 1)
        let k = Int(t), f = t - CGFloat(k)
        let col = lerp(colors[k], colors[min(k + 1, colors.count - 1)], f)
        let twoPi: CGFloat = 2 * CGFloat.pi
        let q: CGFloat = CGFloat.pi / 2
        let a0: CGFloat = CGFloat(i) / CGFloat(n) * twoPi + q
        let a1: CGFloat = (CGFloat(i) + 1.6) / CGFloat(n) * twoPi + q
        ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.setLineCap(.butt)
        ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false); ctx.strokePath()
    }
}
func ringPath(_ r: CGFloat, _ w: CGFloat) -> CGPath { let p = CGMutablePath(); p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2*r, height: 2*r)); return p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 1) }
// soft glow: wide blurred ring underneath
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
ctx.setShadow(offset: .zero, blur: 90, color: CGColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 0.55))
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.5, blue: 0.5, alpha: 0.35)); ctx.setLineWidth(W * 1.6)
ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2*R, height: 2*R)); ctx.strokePath()
ctx.restoreGState()
drawConicRing(R, W)
// rounded caps: end dots so the seam is invisible
ctx.setFillColor(colors[0]); ctx.fillEllipse(in: CGRect(x: c.x - W/2, y: c.y + R - W/2, width: W, height: W))
// inner "window" glyph: a tiny terminal chevron
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)); ctx.setLineWidth(S*0.028); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: c.x - S*0.07, y: c.y + S*0.06)); ctx.addLine(to: CGPoint(x: c.x + S*0.005, y: c.y)); ctx.addLine(to: CGPoint(x: c.x - S*0.07, y: c.y - S*0.06)); ctx.strokePath()
ctx.move(to: CGPoint(x: c.x + S*0.02, y: c.y - S*0.06)); ctx.addLine(to: CGPoint(x: c.x + S*0.09, y: c.y - S*0.06)); ctx.strokePath()
// orbiting agent nodes with connector arcs
for (i, ang) in [0.95, 2.35, 4.1].enumerated() {
    let r2 = R + S*0.115
    let p = CGPoint(x: c.x + CGFloat(Darwin.cos(ang)) * r2, y: c.y + CGFloat(Darwin.sin(ang)) * r2)
    ctx.setFillColor(colors[i*2]); ctx.setShadow(offset: .zero, blur: 24, color: colors[i*2])
    ctx.fillEllipse(in: CGRect(x: p.x - S*0.028, y: p.y - S*0.028, width: S*0.056, height: S*0.056))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.06, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: p.x - S*0.012, y: p.y - S*0.012, width: S*0.024, height: S*0.024))
}
// status pill on top of the ring
let pill = CGRect(x: c.x - S*0.11, y: c.y + R - S*0.04, width: S*0.22, height: S*0.08)
ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.95)); ctx.addPath(CGPath(roundedRect: pill, cornerWidth: S*0.04, cornerHeight: S*0.04, transform: nil)); ctx.fillPath()
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25)); ctx.setLineWidth(3); ctx.addPath(CGPath(roundedRect: pill, cornerWidth: S*0.04, cornerHeight: S*0.04, transform: nil)); ctx.strokePath()
ctx.setFillColor(colors[0]); ctx.fillEllipse(in: CGRect(x: pill.minX + S*0.03, y: pill.midY - S*0.015, width: S*0.03, height: S*0.03))
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
for k in 0..<3 { ctx.addPath(CGPath(roundedRect: CGRect(x: pill.minX + S*0.075 + CGFloat(k) * S*0.036, y: pill.midY - S*0.008, width: S*0.026, height: S*0.016), cornerWidth: 4, cornerHeight: 4, transform: nil)) }
ctx.fillPath()
img.unlockFocus()
let tiff = img.tiffRepresentation!, rep = NSBitmapImageRep(data: tiff)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "assets/icon-1024.png"))
print("ok")
