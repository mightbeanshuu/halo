// halo-overlay — an animated "wave" glow border glued around another app's window.
//
//   halo-overlay list [OwnerName]              -> JSON lines of that app's on-screen windows
//   halo-overlay attach <cgWindowID> <stateFile>
//
// The state file holds one line:  <state>|<label>
//   state: active | idle | done | error | off
import Cocoa
import QuartzCore

// MARK: - window helpers ----------------------------------------------------

struct WinInfo { let id: CGWindowID; let pid: Int32; let layer: Int; let bounds: CGRect; let owner: String; let name: String }

func onScreenWindows(all: Bool = false) -> [WinInfo] {
    let opts: CGWindowListOption = all ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
    guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return arr.compactMap { w in
        guard let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        return WinInfo(id: CGWindowID(id),
                       pid: Int32(w[kCGWindowOwnerPID as String] as? Int ?? 0),
                       layer: w[kCGWindowLayer as String] as? Int ?? 0,
                       bounds: r,
                       owner: w[kCGWindowOwnerName as String] as? String ?? "",
                       name: w[kCGWindowName as String] as? String ?? "")
    }
}

func cgToCocoa(_ r: CGRect) -> NSRect {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
}

// MARK: - palette -----------------------------------------------------------

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    return CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let paletteActive: [CGColor] = [rgb(255,122,64), rgb(255,64,129), rgb(160,84,255), rgb(64,150,255), rgb(64,224,208), rgb(255,196,64), rgb(255,122,64)]
let paletteIdle:   [CGColor] = [rgb(255,140,90), rgb(200,120,255), rgb(255,140,90)]
let paletteDone:   [CGColor] = [rgb(64,220,140), rgb(120,240,200), rgb(64,220,140)]
let paletteError:  [CGColor] = [rgb(255,80,80), rgb(255,140,120), rgb(255,80,80)]

// MARK: - overlay -----------------------------------------------------------

final class Overlay: NSObject {
    let target: CGWindowID
    let statePath: String
    let pad: CGFloat = 8
    let radius: CGFloat = 18
    let lineW: CGFloat = 4.5

    var window: NSWindow!
    var root: CALayer!
    let glow = CAShapeLayer()
    let ring = CALayer()          // holds the gradient, masked to a stroke
    let ringMask = CAShapeLayer()
    let gradient = CAGradientLayer()
    let pill = CALayer()
    let pillText = CATextLayer()
    let dot = CALayer()

    var lastFrame = NSRect.zero
    var state = ""
    var label = ""
    var lastStateRead: TimeInterval = 0

    init(target: CGWindowID, statePath: String) {
        self.target = target; self.statePath = statePath
        super.init()
        buildWindow()
        applyState("idle", "ready", force: true)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .normal
        // NOT canJoinAllSpaces: the halo lives on the target's Space so a swipe carries both together
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient, .moveToActiveSpace]
        w.isReleasedWhenClosed = false
        let v = NSView(frame: w.contentView!.bounds)
        v.wantsLayer = true
        v.layerUsesCoreImageFilters = true
        w.contentView = v
        root = v.layer!
        root.masksToBounds = false

        // soft outer glow
        glow.fillColor = nil
        glow.lineWidth = 18
        glow.strokeColor = rgb(255,120,80, 0.55)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(9, forKey: kCIInputRadiusKey)
            glow.filters = [blur]
        }
        root.addSublayer(glow)

        // rotating conic gradient, masked to a rounded-rect stroke
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradient.colors = paletteActive
        ring.addSublayer(gradient)
        ringMask.fillColor = nil
        ringMask.strokeColor = CGColor.black
        ringMask.lineWidth = lineW
        ring.mask = ringMask
        root.addSublayer(ring)

        // status pill
        pill.backgroundColor = rgb(18,18,22, 0.88)
        pill.cornerRadius = 12
        pill.borderWidth = 1
        pill.borderColor = rgb(255,255,255, 0.18)
        dot.cornerRadius = 4
        dot.backgroundColor = rgb(255,122,64)
        pillText.fontSize = 11.5
        pillText.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        pillText.foregroundColor = CGColor.white
        pillText.alignmentMode = .left
        pillText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        pillText.truncationMode = .end
        pill.addSublayer(dot)
        pill.addSublayer(pillText)
        root.addSublayer(pill)

        window = w
    }

    func layout(_ size: CGSize) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        let inner = CGRect(x: pad - lineW/2, y: pad - lineW/2, width: size.width - 2*pad + lineW, height: size.height - 2*pad + lineW)
        let path = CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ringMask.path = path
        ringMask.frame = root.bounds
        ring.frame = root.bounds
        glow.path = path
        glow.frame = root.bounds
        // gradient square big enough to cover the view while rotating
        let diag = sqrt(size.width*size.width + size.height*size.height) * 1.02
        gradient.bounds = CGRect(x: 0, y: 0, width: diag, height: diag)
        gradient.position = CGPoint(x: size.width/2, y: size.height/2)
        // pill: top-center, straddling the border
        let textW = min(max(60, (label.count > 0 ? CGFloat(label.count) : 8) * 7.2 + 16), size.width - 60)
        let pillW = textW + 30
        pill.frame = CGRect(x: (size.width - pillW)/2, y: size.height - pad - 12, width: pillW, height: 24)
        dot.frame = CGRect(x: 11, y: 8, width: 8, height: 8)
        pillText.frame = CGRect(x: 26, y: 4.5, width: textW, height: 16)
        CATransaction.commit()
    }

    // MARK: state -------------------------------------------------------------

    func readState() {
        guard let s = try? String(contentsOfFile: statePath, encoding: .utf8) else { return }
        let line = s.split(separator: "\n").first.map(String.init) ?? ""
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        let st = parts.first?.trimmingCharacters(in: .whitespaces) ?? "idle"
        let lb = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        applyState(st, lb)
    }

    func applyState(_ st: String, _ lb: String, force: Bool = false) {
        if !force && st == state && lb == label { return }
        let stateChanged = st != state
        state = st; label = lb
        pillText.string = lb.isEmpty ? st : lb
        if stateChanged { restyle() }
        layout(window.frame.size)
    }

    func restyle() {
        gradient.removeAllAnimations()
        ring.removeAllAnimations()
        glow.removeAllAnimations()
        dot.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch state {
        case "active":
            gradient.colors = paletteActive
            ring.opacity = 1
            glow.strokeColor = rgb(255,120,80, 0.6)
            glow.opacity = 1
            dot.backgroundColor = rgb(255,122,64)
            spin(duration: 2.4)
            pulse(glow, from: 0.55, to: 1.0, duration: 1.4)
            pulse(dot, from: 0.3, to: 1.0, duration: 0.9)
        case "done":
            gradient.colors = paletteDone
            ring.opacity = 0.95
            glow.strokeColor = rgb(64,220,140, 0.5)
            glow.opacity = 0.8
            dot.backgroundColor = rgb(64,220,140)
            spin(duration: 9)
        case "error":
            gradient.colors = paletteError
            ring.opacity = 1
            glow.strokeColor = rgb(255,80,80, 0.6)
            glow.opacity = 1
            dot.backgroundColor = rgb(255,80,80)
            pulse(glow, from: 0.4, to: 1.0, duration: 0.7)
        case "off":
            ring.opacity = 0; glow.opacity = 0
        default: // idle
            gradient.colors = paletteIdle
            ring.opacity = 0.55
            glow.strokeColor = rgb(255,140,90, 0.35)
            glow.opacity = 0.6
            dot.backgroundColor = rgb(200,120,255)
            spin(duration: 14)
        }
        pill.opacity = state == "off" ? 0 : 1
        CATransaction.commit()
    }

    func spin(duration: Double) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0; a.toValue = -2 * Double.pi
        a.duration = duration; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        gradient.add(a, forKey: "spin")
    }

    func pulse(_ layer: CALayer, from: Float, to: Float, duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = to
        a.duration = duration; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "pulse")
    }

    // MARK: tracking ------------------------------------------------------------

    func tick() {
        let now = Date().timeIntervalSince1970
        if now - lastStateRead > 0.25 { lastStateRead = now; readState() }

        let wins = onScreenWindows()
        guard let t = wins.first(where: { $0.id == target }) else {
            // gone from this Space (minimised / other desktop) — or closed for good?
            if let all = CGWindowListCopyWindowInfo([.optionIncludingWindow], target) as? [[String: Any]], !all.isEmpty {
                window.orderOut(nil); return
            }
            NSApp.terminate(nil); return
        }
        var f = cgToCocoa(t.bounds)
        f = f.insetBy(dx: -pad, dy: -pad)
        if f != lastFrame {
            lastFrame = f
            window.setFrame(f, display: true)
            layout(f.size)
        }
        let mine = CGWindowID(window.windowNumber)
        let iAmOnThisSpace = wins.contains { $0.id == mine }
        if !window.isVisible || !iAmOnThisSpace {
            // target is here but we are on another Space (or hidden): hop over to it
            window.orderFrontRegardless()   // .moveToActiveSpace carries it to this Space
        }
        // keep exactly one step above the target in z-order (works across apps)
        window.order(.above, relativeTo: Int(target))
    }
}

// MARK: - main ----------------------------------------------------------------

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "screen" {
    let full = NSScreen.screens.first?.frame ?? .zero
    let f = args.contains("--full") ? full : (NSScreen.screens.first?.visibleFrame ?? .zero)
    // report in CG (top-left origin) coordinates
    print("{\"x\":\(Int(f.minX)),\"y\":\(Int(full.height - f.maxY)),\"w\":\(Int(f.width)),\"h\":\(Int(f.height))}")
    exit(0)
}
if args.count >= 2 && args[1] == "list" {
    let owner = args.count > 2 ? args[2] : "Terminal"
    let all = args.contains("--all")
    for w in onScreenWindows(all: all) where w.owner == owner && w.layer == 0 {
        let name = w.name.replacingOccurrences(of: "\"", with: "'")
        print("{\"id\":\(w.id),\"pid\":\(w.pid),\"x\":\(Int(w.bounds.minX)),\"y\":\(Int(w.bounds.minY)),\"w\":\(Int(w.bounds.width)),\"h\":\(Int(w.bounds.height)),\"name\":\"\(name)\"}")
    }
    exit(0)
}
guard args.count >= 4, args[1] == "attach", let id = UInt32(args[2]) else {
    FileHandle.standardError.write("usage: halo-overlay list [Owner] | attach <windowID> <stateFile>\n".data(using: .utf8)!)
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let overlay = Overlay(target: id, statePath: args[3])
_ = overlay
app.run()
