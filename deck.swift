// halo-deck — the workspace: halos around every agent window, animated arrow
// connectors from the orchestrator window to each agent, and an interactive HUD
// (host CPU/mem, per-agent CPU, tokens, context %, rate-limit %, launch/focus/
// send/close controls, live file panel with PDF + text preview/edit).
//
//   halo-deck [--orch <cgWindowID>] [--orch-session <claudeSessionId>] [--clean]
//
// Reads ~/.halo/<name>.json + .state (written by the `halo` driver) and
// ~/.halo/status/<sessionId>.json (written by the Claude Code statusline hook).
import Cocoa
import SwiftUI
import Charts
import PDFKit
import Speech
import AVFoundation
import ScreenCaptureKit

/// Screenshot of one window (any Space) via ScreenCaptureKit; falls back to the screencapture CLI.
func captureWindow(_ id: CGWindowID, completion: @escaping (NSImage?) -> Void) {
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let win = content.windows.first(where: { $0.windowID == id }) else { completion(captureViaCLI(id)); return }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            cfg.width = Int(win.frame.width * scale); cfg.height = Int(win.frame.height * scale)
            cfg.showsCursor = false
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            completion(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        } catch {
            completion(captureViaCLI(id))
        }
    }
}
func captureViaCLI(_ id: CGWindowID) -> NSImage? {
    let p = NSTemporaryDirectory() + "halo-live-\(id).png"
    run(["screencapture", "-x", "-l", "\(id)", p])
    return NSImage(contentsOfFile: p)
}

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let HALO_DIR = HOME + "/.halo"
let HUD_WIDTH: CGFloat = 400
let VERSION: String = {
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for c in [here.appendingPathComponent("../VERSION"), here.appendingPathComponent("VERSION")] {
        if let v = try? String(contentsOf: c, encoding: .utf8) { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return "dev"
}()

// MARK: - window helpers ------------------------------------------------------

struct WinInfo { let id: CGWindowID; let pid: Int32; let layer: Int; let bounds: CGRect; let owner: String; let name: String }

func cgWindows(all: Bool = false) -> [WinInfo] {
    let opts: CGWindowListOption = all ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
    guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return arr.compactMap { w in
        guard let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        return WinInfo(id: CGWindowID(id), pid: Int32(w[kCGWindowOwnerPID as String] as? Int ?? 0),
                       layer: w[kCGWindowLayer as String] as? Int ?? 0, bounds: r,
                       owner: w[kCGWindowOwnerName as String] as? String ?? "",
                       name: w[kCGWindowName as String] as? String ?? "")
    }
}

func cgToCocoa(_ r: CGRect) -> NSRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let palActive: [CGColor] = [rgb(255,122,64), rgb(255,64,129), rgb(160,84,255), rgb(64,150,255), rgb(64,224,208), rgb(255,196,64), rgb(255,122,64)]
let palIdle:   [CGColor] = [rgb(255,140,90), rgb(200,120,255), rgb(255,140,90)]
let palDone:   [CGColor] = [rgb(64,220,140), rgb(120,240,200), rgb(64,220,140)]
let palError:  [CGColor] = [rgb(255,80,80), rgb(255,140,120), rgb(255,80,80)]
let palOrch:   [CGColor] = [rgb(90,170,255), rgb(180,220,255), rgb(120,140,255), rgb(90,170,255)]

func stateColor(_ s: String) -> CGColor {
    switch s {
    case "active": return rgb(255,122,64)
    case "done": return rgb(64,220,140)
    case "error": return rgb(255,80,80)
    case "orch": return rgb(90,170,255)
    default: return rgb(200,120,255)
    }
}

@discardableResult
func run(_ args: [String], cwd: String? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

func runAsync(_ args: [String]) {
    DispatchQueue.global(qos: .userInitiated).async { run(args) }
}

// MARK: - model ---------------------------------------------------------------

final class Session: ObservableObject, Identifiable {
    let id: String
    var name: String { id }
    @Published var kind = "tmux"
    @Published var app = ""
    @Published var owner = "Terminal"
    @Published var cwd = ""
    @Published var cmd = ""
    @Published var window: CGWindowID? = nil
    @Published var pid: Int32? = nil
    @Published var openedTs: Double = 0
    @Published var state = "idle"
    @Published var label = ""
    @Published var cpu: Double = 0
    @Published var cpuHist: [Double] = Array(repeating: 0, count: 40)
    @Published var rssMB: Double = 0
    @Published var model = ""
    @Published var ctxPct: Double? = nil
    @Published var limit5h: Double? = nil
    @Published var limit7d: Double? = nil
    @Published var cost: Double? = nil
    @Published var tokIn = 0
    @Published var tokOut = 0
    @Published var onScreen = false
    @Published var prompt = ""
    var rect = CGRect.zero
    var transcript: String? = nil
    var isClaude: Bool { kind == "tmux" && (cmd.hasPrefix("claude") || id == "you") }
    init(id: String) { self.id = id }
}

struct Todo: Identifiable, Codable, Equatable {
    var id: Int
    var text: String
    var done: Bool
    var created: Double
}

struct AgentAction: Identifiable, Equatable {
    let id: String
    let time: Date
    let agent: String
    let tool: String      // short tool name, e.g. "navigate", "computer"
    let summary: String   // key inputs
    var isChrome: Bool { tool.hasPrefix("chrome:") }
}

struct FileItem: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let dir: String
    let mtime: Date
    var isPDF: Bool { path.lowercased().hasSuffix(".pdf") }
}

final class Deck: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var orch = Session(id: "you")
    @Published var cpuHist: [Double] = Array(repeating: 0, count: 60)
    @Published var cpuNow: Double = 0
    @Published var memUsedGB: Double = 0
    @Published var memTotalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    @Published var load1: Double = 0
    @Published var files: [FileItem] = []
    @Published var selected: FileItem? = nil
    @Published var clean = false
    @Published var showConnectors = true
    @Published var tokensTotalOut = 0
    @Published var tab = 0
    @Published var autoTile = true
    @Published var focus = false
    @Published var todos: [Todo] = []
    @Published var actions: [AgentAction] = []
    @Published var liveImage: NSImage? = nil
    @Published var liveTitle = ""
    @Published var autoLive = true
    @Published var liveWindowOpen = false
    @Published var dictation = Dictation()
    var orchWindow: CGWindowID? = nil
    var orchSession: String? = nil
}

// MARK: - halo window (one per tracked window) --------------------------------

final class HaloWindow {
    let target: CGWindowID
    let pad: CGFloat = 8, radius: CGFloat = 18, lineW: CGFloat = 4.5
    let window: NSWindow
    let root: CALayer
    let glow = CAShapeLayer(), ring = CALayer(), ringMask = CAShapeLayer(), gradient = CAGradientLayer()
    let pill = CALayer(), pillText = CATextLayer(), dot = CALayer()
    var lastFrame = NSRect.zero
    var state = "", label = ""

    init(target: CGWindowID) {
        self.target = target
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.ignoresMouseEvents = true; w.level = .normal
        w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient, .moveToActiveSpace]
        w.isReleasedWhenClosed = false
        let v = NSView(frame: w.contentView!.bounds); v.wantsLayer = true; v.layerUsesCoreImageFilters = true
        w.contentView = v
        root = v.layer!; root.masksToBounds = false
        window = w

        glow.fillColor = nil; glow.lineWidth = 18; glow.strokeColor = rgb(255,120,80, 0.55)
        if let blur = CIFilter(name: "CIGaussianBlur") { blur.setValue(9, forKey: kCIInputRadiusKey); glow.filters = [blur] }
        root.addSublayer(glow)
        gradient.type = .conic; gradient.startPoint = CGPoint(x: 0.5, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = palActive
        ring.addSublayer(gradient)
        ringMask.fillColor = nil; ringMask.strokeColor = CGColor.black; ringMask.lineWidth = lineW
        ring.mask = ringMask
        root.addSublayer(ring)
        pill.backgroundColor = rgb(18,18,22, 0.88); pill.cornerRadius = 12; pill.borderWidth = 1; pill.borderColor = rgb(255,255,255, 0.18)
        dot.cornerRadius = 4
        pillText.fontSize = 11.5; pillText.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        pillText.foregroundColor = CGColor.white; pillText.truncationMode = .end
        pillText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        pill.addSublayer(dot); pill.addSublayer(pillText); root.addSublayer(pill)
        apply(state: "idle", label: "ready")
    }

    func layout(_ size: CGSize) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        let inner = CGRect(x: pad - lineW/2, y: pad - lineW/2, width: size.width - 2*pad + lineW, height: size.height - 2*pad + lineW)
        let path = CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ringMask.path = path; ringMask.frame = root.bounds; ring.frame = root.bounds
        glow.path = path; glow.frame = root.bounds
        let diag = sqrt(size.width*size.width + size.height*size.height) * 1.02
        gradient.bounds = CGRect(x: 0, y: 0, width: diag, height: diag)
        gradient.position = CGPoint(x: size.width/2, y: size.height/2)
        let textW = min(max(60, CGFloat(max(label.count, 6)) * 7.2 + 16), size.width - 60)
        let pillW = textW + 30
        pill.frame = CGRect(x: (size.width - pillW)/2, y: size.height - pad - 12, width: pillW, height: 24)
        dot.frame = CGRect(x: 11, y: 8, width: 8, height: 8)
        pillText.frame = CGRect(x: 26, y: 4.5, width: textW, height: 16)
        CATransaction.commit()
    }

    func apply(state st: String, label lb: String) {
        if st == state && lb == label { return }
        let changed = st != state
        state = st; label = lb
        pillText.string = lb.isEmpty ? st : lb
        if changed { restyle() }
        layout(window.frame.size)
    }

    func restyle() {
        gradient.removeAllAnimations(); glow.removeAllAnimations(); dot.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switch state {
        case "active":
            gradient.colors = palActive; ring.opacity = 1
            glow.strokeColor = rgb(255,120,80, 0.6); glow.opacity = 1; dot.backgroundColor = rgb(255,122,64)
            spin(2.4); pulse(glow, 0.55, 1.0, 1.4); pulse(dot, 0.3, 1.0, 0.9)
        case "done":
            gradient.colors = palDone; ring.opacity = 0.95
            glow.strokeColor = rgb(64,220,140, 0.5); glow.opacity = 0.8; dot.backgroundColor = rgb(64,220,140); spin(9)
        case "error":
            gradient.colors = palError; ring.opacity = 1
            glow.strokeColor = rgb(255,80,80, 0.6); glow.opacity = 1; dot.backgroundColor = rgb(255,80,80); pulse(glow, 0.4, 1.0, 0.7)
        case "orch":
            gradient.colors = palOrch; ring.opacity = 0.9
            glow.strokeColor = rgb(90,170,255, 0.45); glow.opacity = 0.9; dot.backgroundColor = rgb(90,170,255); spin(6)
        case "off":
            ring.opacity = 0; glow.opacity = 0
        default:
            gradient.colors = palIdle; ring.opacity = 0.55
            glow.strokeColor = rgb(255,140,90, 0.35); glow.opacity = 0.6; dot.backgroundColor = rgb(200,120,255); spin(14)
        }
        pill.opacity = state == "off" ? 0 : 1
        CATransaction.commit()
    }

    func spin(_ d: Double) {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0; a.toValue = -2 * Double.pi; a.duration = d; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        gradient.add(a, forKey: "spin")
    }
    func pulse(_ l: CALayer, _ from: Float, _ to: Float, _ d: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = to; a.duration = d; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(a, forKey: "pulse")
    }

    /// returns the cocoa rect of the target (nil if not on this Space)
    @discardableResult
    func track(_ wins: [WinInfo]) -> NSRect? {
        guard let t = wins.first(where: { $0.id == target }) else { window.orderOut(nil); return nil }
        let f = cgToCocoa(t.bounds).insetBy(dx: -pad, dy: -pad)
        if f != lastFrame { lastFrame = f; window.setFrame(f, display: true); layout(f.size) }
        let mine = CGWindowID(window.windowNumber)
        if !window.isVisible || !wins.contains(where: { $0.id == mine }) {
            window.orderFrontRegardless()   // .moveToActiveSpace carries it to this Space
        }
        window.order(.above, relativeTo: Int(target))
        return f
    }

    func close() { window.orderOut(nil) }
}

// MARK: - connector canvas ----------------------------------------------------

final class Connector {
    let line = CAShapeLayer(), glow = CAShapeLayer(), head = CAShapeLayer(), tag = CALayer(), tagText = CATextLayer()
    let startDot = CALayer(), endDot = CALayer()
    var state = ""
    init(parent: CALayer) {
        for l in [glow, line] {
            l.fillColor = nil; l.lineCap = .round; l.lineJoin = .round
        }
        glow.lineWidth = 10; glow.opacity = 0.35
        if let blur = CIFilter(name: "CIGaussianBlur") { blur.setValue(6, forKey: kCIInputRadiusKey); glow.filters = [blur] }
        line.lineWidth = 2.5
        head.lineWidth = 0
        for d in [startDot, endDot] { d.bounds = CGRect(x: 0, y: 0, width: 9, height: 9); d.cornerRadius = 4.5; d.borderWidth = 2; d.borderColor = rgb(10,10,14, 0.9) }
        tag.backgroundColor = rgb(18,18,22, 0.9); tag.cornerRadius = 9; tag.borderWidth = 1; tag.borderColor = rgb(255,255,255, 0.16)
        tagText.fontSize = 10.5; tagText.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        tagText.foregroundColor = CGColor.white; tagText.alignmentMode = .center
        tagText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        tag.addSublayer(tagText)
        [glow, line, head, startDot, endDot, tag].forEach(parent.addSublayer)
    }

    func style(_ st: String) {
        if st == state { return }
        state = st
        line.removeAllAnimations()
        let c = stateColor(st)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        line.strokeColor = c; glow.strokeColor = c; head.fillColor = c
        startDot.backgroundColor = c; endDot.backgroundColor = c
        switch st {
        case "active":
            line.lineDashPattern = [12, 9]; line.opacity = 1; glow.opacity = 0.5; flow(0.55)
        case "done":
            line.lineDashPattern = nil; line.opacity = 0.9; glow.opacity = 0.35
        case "error":
            line.lineDashPattern = [4, 6]; line.opacity = 1; glow.opacity = 0.5; flow(0.3)
        default:
            line.lineDashPattern = [6, 10]; line.opacity = 0.6; glow.opacity = 0.2; flow(2.2)
        }
        CATransaction.commit()
    }
    func flow(_ d: Double) {
        let a = CABasicAnimation(keyPath: "lineDashPhase")
        a.fromValue = 0; a.toValue = -21; a.duration = d; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        line.add(a, forKey: "flow")
    }

    func update(from o: CGRect, to s: CGRect, name: String, label: String) {
        // anchor on the facing edges; horizontal preferred
        var p0 = CGPoint.zero, p3 = CGPoint.zero, c1 = CGPoint.zero, c2 = CGPoint.zero
        let gapX = max(s.minX - o.maxX, o.minX - s.maxX)
        let gapY = max(s.minY - o.maxY, o.minY - s.maxY)
        if gapX >= gapY {
            if s.midX >= o.midX { p0 = CGPoint(x: o.maxX, y: o.midY); p3 = CGPoint(x: s.minX, y: s.midY) }
            else { p0 = CGPoint(x: o.minX, y: o.midY); p3 = CGPoint(x: s.maxX, y: s.midY) }
            let k = max(abs(p3.x - p0.x) * 0.5, 60) * (p3.x >= p0.x ? 1 : -1)
            c1 = CGPoint(x: p0.x + k, y: p0.y); c2 = CGPoint(x: p3.x - k, y: p3.y)
        } else {
            if s.midY >= o.midY { p0 = CGPoint(x: o.midX, y: o.maxY); p3 = CGPoint(x: s.midX, y: s.minY) }
            else { p0 = CGPoint(x: o.midX, y: o.minY); p3 = CGPoint(x: s.midX, y: s.maxY) }
            let k = max(abs(p3.y - p0.y) * 0.5, 60) * (p3.y >= p0.y ? 1 : -1)
            c1 = CGPoint(x: p0.x, y: p0.y + k); c2 = CGPoint(x: p3.x, y: p3.y - k)
        }
        let path = CGMutablePath()
        path.move(to: p0); path.addCurve(to: p3, control1: c1, control2: c2)
        // arrow head oriented along the end tangent
        let ang = atan2(p3.y - c2.y, p3.x - c2.x)
        let hp = CGMutablePath()
        let L: CGFloat = 13, W: CGFloat = 6.5
        let tip = p3
        let base = CGPoint(x: tip.x - cos(ang) * L, y: tip.y - sin(ang) * L)
        let n = CGPoint(x: -sin(ang) * W, y: cos(ang) * W)
        hp.move(to: tip); hp.addLine(to: CGPoint(x: base.x + n.x, y: base.y + n.y)); hp.addLine(to: CGPoint(x: base.x - n.x, y: base.y - n.y)); hp.closeSubpath()
        // midpoint of the cubic (t = 0.5)
        let t: CGFloat = 0.72, u = 1 - t
        func b(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { u*u*u*a + 3*u*u*t*b + 3*u*t*t*c + t*t*t*d }
        let mid = CGPoint(x: b(p0.x, c1.x, c2.x, p3.x), y: b(p0.y, c1.y, c2.y, p3.y))
        let text = name
        let tw = min(CGFloat(text.count) * 6.4 + 18, 160)

        CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
        line.path = path; glow.path = path; head.path = hp
        startDot.position = p0; endDot.position = p3
        tag.bounds = CGRect(x: 0, y: 0, width: tw, height: 18); tag.position = mid
        tagText.frame = CGRect(x: 0, y: 2.5, width: tw, height: 14); tagText.string = text
        CATransaction.commit()
    }

    func remove() { [glow, line, head, startDot, endDot, tag].forEach { $0.removeFromSuperlayer() } }
    func hide(_ h: Bool) { [glow, line, head, startDot, endDot, tag].forEach { $0.isHidden = h } }
}

final class Canvas {
    let window: NSWindow
    let root: CALayer
    var connectors: [String: Connector] = [:]
    init() {
        let f = NSScreen.screens.first?.frame ?? .zero
        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary, .transient]
        w.isReleasedWhenClosed = false
        let v = NSView(frame: w.contentView!.bounds); v.wantsLayer = true; v.layerUsesCoreImageFilters = true
        w.contentView = v; root = v.layer!
        window = w
        w.orderFrontRegardless()
    }
    func sync(orch: CGRect?, sessions: [Session], enabled: Bool) {
        let names = Set(sessions.map { $0.id })
        for (k, c) in connectors where !names.contains(k) { c.remove(); connectors[k] = nil }
        for s in sessions {
            let c = connectors[s.id] ?? { let c = Connector(parent: root); connectors[s.id] = c; return c }()
            guard enabled, let o = orch, s.onScreen else { c.hide(true); continue }
            c.hide(false)
            c.style(s.state)
            c.update(from: o.insetBy(dx: -10, dy: -10), to: s.rect.insetBy(dx: -10, dy: -10), name: s.name, label: s.label)
        }
    }
}

// MARK: - backdrop ------------------------------------------------------------

final class BackdropView: NSView {
    override func draw(_ dirty: NSRect) {
        let g = NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1), NSColor(srgbRed: 0.09, green: 0.07, blue: 0.13, alpha: 1)])!
        g.draw(in: bounds, angle: 60)
        NSColor(white: 1, alpha: 0.06).setFill()
        var y: CGFloat = 20
        while y < bounds.height { var x: CGFloat = 20; while x < bounds.width { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill(); x += 28 }; y += 28 }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.35)]
        ("HALO WORKSPACE" as NSString).draw(at: NSPoint(x: 24, y: 18), withAttributes: attrs)
    }
}
final class Backdrop {
    let window: NSWindow
    init() {
        let f = NSScreen.screens.first?.frame ?? .zero
        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false; w.ignoresMouseEvents = true
        w.contentView = BackdropView(frame: w.contentView!.bounds)
        window = w
    }
    func set(_ on: Bool) { if on { window.orderFrontRegardless() } else { window.orderOut(nil) } }
}

// MARK: - stats ---------------------------------------------------------------

struct CPUTicks { var user: UInt64 = 0, sys: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0 }
func cpuTicks() -> CPUTicks? {
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    var info = host_cpu_load_info()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard r == KERN_SUCCESS else { return nil }
    return CPUTicks(user: UInt64(info.cpu_ticks.0), sys: UInt64(info.cpu_ticks.1), idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
}
func memUsedBytes() -> UInt64 {
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    var vm = vm_statistics64()
    let r = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard r == KERN_SUCCESS else { return 0 }
    let page = UInt64(vm_kernel_page_size)
    return (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
}

struct ProcRow { let ppid: Int32; let cpu: Double; let rssKB: Double }
func psTable() -> [Int32: ProcRow] {
    var t: [Int32: ProcRow] = [:]
    for line in run(["ps", "-axo", "pid=,ppid=,%cpu=,rss="]).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 4, let pid = Int32(f[0]), let ppid = Int32(f[1]), let cpu = Double(f[2]), let rss = Double(f[3]) else { continue }
        t[pid] = ProcRow(ppid: ppid, cpu: cpu, rssKB: rss)
    }
    return t
}
func treeSum(_ roots: [Int32], _ t: [Int32: ProcRow]) -> (cpu: Double, rssMB: Double) {
    var children: [Int32: [Int32]] = [:]
    for (pid, r) in t { children[r.ppid, default: []].append(pid) }
    var cpu = 0.0, rss = 0.0
    var stack = roots, seen = Set<Int32>()
    while let p = stack.popLast() {
        if seen.contains(p) { continue }; seen.insert(p)
        if let r = t[p] { cpu += r.cpu; rss += r.rssKB }
        stack.append(contentsOf: children[p] ?? [])
    }
    return (cpu, rss / 1024)
}

struct StatusInfo { let sessionId: String; let cwd: String; let model: String; let ctx: Double?; let l5: Double?; let l7: Double?; let cost: Double?; let transcript: String?; let mtime: Date }
func readStatusFiles() -> [StatusInfo] {
    let dir = HALO_DIR + "/status"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var out: [StatusInfo] = []
    for n in names where n.hasSuffix(".json") {
        let p = dir + "/" + n
        guard let d = FileManager.default.contents(atPath: p),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? Date.distantPast
        let ws = j["workspace"] as? [String: Any]
        let cwd = (ws?["current_dir"] as? String) ?? (j["cwd"] as? String) ?? ""
        let model = ((j["model"] as? [String: Any])?["display_name"] as? String) ?? ""
        let ctx = (j["context_window"] as? [String: Any])?["used_percentage"] as? Double
        var l5: Double? = nil, l7: Double? = nil
        if let rl = j["rate_limits"] as? [String: Any] {
            for (k, v) in rl {
                guard let dv = v as? [String: Any] else { continue }
                let used = (dv["used_percentage"] as? Double) ?? (dv["used_percent"] as? Double)
                let key = k.lowercased()
                if key.contains("five") || key.contains("5") || key.contains("primary") { l5 = used }
                else if key.contains("seven") || key.contains("7") || key.contains("week") { l7 = used }
            }
        }
        let cost = (j["cost"] as? [String: Any])?["total_cost_usd"] as? Double
        out.append(StatusInfo(sessionId: String(n.dropLast(5)), cwd: cwd, model: model, ctx: ctx, l5: l5, l7: l7, cost: cost,
                              transcript: j["transcript_path"] as? String, mtime: mtime))
    }
    return out
}

final class TranscriptReader {
    struct Acc { var offset: UInt64 = 0; var usage: [String: (Int, Int)] = [:]; var partial = ""; var pending: [AgentAction] = [] }
    var accs: [String: Acc] = [:]
    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    /// tool_use blocks seen since the last drain (agent name filled in by the caller)
    func drainActions(_ path: String, agent: String) -> [AgentAction] {
        guard var acc = accs[path] else { return [] }
        let out = acc.pending.map { AgentAction(id: $0.id, time: $0.time, agent: agent, tool: $0.tool, summary: $0.summary) }
        acc.pending = []; accs[path] = acc
        return out
    }
    func totals(_ path: String) -> (inp: Int, out: Int) {
        var acc = accs[path] ?? Acc()
        guard let fh = FileHandle(forReadingAtPath: path) else { return (0, 0) }
        defer { fh.closeFile() }
        fh.seek(toFileOffset: acc.offset)
        let data = fh.readDataToEndOfFile()
        acc.offset += UInt64(data.count)
        let text = acc.partial + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        acc.partial = lines.removeLast()
        for l in lines where l.contains("\"assistant\"") {
            guard let d = l.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (j["type"] as? String) == "assistant", let m = j["message"] as? [String: Any] else { continue }
            if let content = m["content"] as? [[String: Any]] {
                let ts = (j["timestamp"] as? String).flatMap { TranscriptReader.iso.date(from: $0) } ?? Date()
                for c in content where (c["type"] as? String) == "tool_use" {
                    let name = c["name"] as? String ?? "tool"
                    let input = c["input"] as? [String: Any] ?? [:]
                    var tool = name
                    if name.hasPrefix("mcp__claude-in-chrome__") { tool = "chrome:" + name.dropFirst("mcp__claude-in-chrome__".count) }
                    else if name.hasPrefix("mcp__") { tool = name.dropFirst(5).replacingOccurrences(of: "__", with: ":") }
                    var bits: [String] = []
                    for k in ["action", "url", "text", "coordinate", "command", "file_path", "pattern", "description", "prompt", "query", "selector", "ref", "key"] {
                        if let v = input[k] { let str = "\(v)".replacingOccurrences(of: "\n", with: " "); bits.append(k == "action" ? str : "\(k)=\(str.prefix(70))") }
                    }
                    let id = (c["id"] as? String) ?? UUID().uuidString
                    acc.pending.append(AgentAction(id: id, time: ts, agent: "", tool: tool, summary: bits.joined(separator: " · ")))
                }
            }
            guard let u = m["usage"] as? [String: Any] else { continue }
            let id = (m["id"] as? String) ?? UUID().uuidString
            let inp = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
            let out = u["output_tokens"] as? Int ?? 0
            let prev = acc.usage[id] ?? (0, 0)
            acc.usage[id] = (max(prev.0, inp), max(prev.1, out))
        }
        accs[path] = acc
        var ti = 0, to = 0
        for (_, v) in acc.usage { ti += v.0; to += v.1 }
        return (ti, to)
    }
}

func isMachO(_ path: String) -> Bool {
    guard let fh = FileHandle(forReadingAtPath: path) else { return false }
    defer { fh.closeFile() }
    let d = fh.readData(ofLength: 4)
    guard d.count == 4 else { return false }
    let magic = d.withUnsafeBytes { $0.load(as: UInt32.self) }
    return [0xfeedfacf, 0xcffaedfe, 0xfeedface, 0xcefaedfe, 0xcafebabe, 0xbebafeca].contains(magic)
}
let SKIP_DIRS: Set<String> = ["node_modules", ".git", "venv", ".venv", "dist", "build", "target", "__pycache__", ".next", "Library", ".cache", "Pods", "DerivedData"]
func recentFiles(in dirs: [String], minutes: Double = 45, limit: Int = 18) -> [FileItem] {
    var out: [FileItem] = []
    let cutoff = Date().addingTimeInterval(-minutes * 60)
    let fm = FileManager.default
    for dir in dirs where dir != HOME && !dir.isEmpty {
        guard let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
        var visited = 0
        while let u = e.nextObject() as? URL {
            visited += 1; if visited > 8000 { break }
            let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey])
            if rv?.isDirectory == true { if SKIP_DIRS.contains(u.lastPathComponent) { e.skipDescendants() }; continue }
            guard rv?.isRegularFile == true, let m = rv?.contentModificationDate, m > cutoff else { continue }
            if u.deletingLastPathComponent().lastPathComponent == "bin" || isMachO(u.path) { continue }
            out.append(FileItem(path: u.path, name: u.lastPathComponent, dir: String(u.deletingLastPathComponent().path.dropFirst(dir.count)), mtime: m))
        }
    }
    out.sort { $0.mtime > $1.mtime }
    return Array(out.prefix(limit))
}

// MARK: - controller ----------------------------------------------------------

final class DeckController {
    let deck = Deck()
    let canvas = Canvas()
    let backdrop = Backdrop()
    var halos: [CGWindowID: HaloWindow] = [:]
    var orchHalo: HaloWindow? = nil
    var hud: NSPanel!
    var prevTicks = cpuTicks()
    let transcripts = TranscriptReader()
    var metaMtimes: [String: Date] = [:]
    let statsQ = DispatchQueue(label: "halo.stats", qos: .utility)
    var cleanObs: Any? = nil
    var layoutKey = "", layoutChangedAt: Date? = nil
    var todoMtime: Date = .distantPast
    var liveWindow: NSWindow? = nil
    var liveTick = 0

    init(orch: CGWindowID?, orchSession: String?, clean: Bool) {
        deck.orchWindow = orch; deck.orchSession = orchSession
        deck.orch.state = "orch"; deck.orch.label = "orchestrator · you"; deck.orch.cmd = "claude"
        deck.orch.window = orch
        if let pid = ProcessInfo.processInfo.environment["CLAUDE_PID"], let p = Int32(pid) { deck.orch.pid = p }
        deck.orch.cwd = ProcessInfo.processInfo.environment["PWD"] ?? ""
        buildHUD()
        if clean { deck.clean = true; backdrop.set(true) }
        if let o = orch { orchHalo = HaloWindow(target: o); orchHalo?.apply(state: "orch", label: "orchestrator · you") }
        Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in self?.geometryTick() }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.metaTick() }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.statsTick() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.liveCapture() }
        metaTick(); statsTick()
    }

    func buildHUD() {
        let scr = NSScreen.screens.first?.visibleFrame ?? .zero
        let f = NSRect(x: scr.maxX - HUD_WIDTH - 10, y: scr.minY + 10, width: HUD_WIDTH, height: scr.height - 20)
        let p = KeyPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: f.size))
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 22; effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1; effect.layer?.borderColor = rgb(255,255,255, 0.14)
        effect.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: HUDView(deck: deck, controller: self))
        host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        p.contentView = effect
        p.orderFrontRegardless()
        hud = p
    }

    // 60 Hz: window geometry, halos, connectors
    func geometryTick() {
        let wins = cgWindows()
        var orchRect: CGRect? = nil
        if let oh = orchHalo { orchRect = oh.track(wins) }
        deck.orch.onScreen = orchRect != nil
        for s in deck.sessions {
            guard let w = s.window else { s.onScreen = false; continue }
            let h = halos[w] ?? { let h = HaloWindow(target: w); halos[w] = h; return h }()
            h.apply(state: s.state, label: s.label)
            if let r = h.track(wins) { s.rect = r; if !s.onScreen { s.onScreen = true } }
            else if s.onScreen { s.onScreen = false }
        }
        let live = Set(deck.sessions.compactMap { $0.window })
        for (id, h) in halos where !live.contains(id) { h.close(); halos[id] = nil }
        canvas.sync(orch: orchRect, sessions: deck.sessions, enabled: deck.showConnectors)
        backdrop.set(deck.clean)
        // smart alignment: when the set of visible agents changes, settle 0.8 s then re-tile
        let key = deck.sessions.filter { $0.onScreen }.map { $0.id }.sorted().joined(separator: ",") + "|" + (orchRect == nil ? "-" : "o")
        if key != layoutKey { layoutKey = key; layoutChangedAt = Date() }
        else if deck.autoTile, let t = layoutChangedAt, Date().timeIntervalSince(t) > 0.8 { layoutChangedAt = nil; tile() }
    }

    // ---- todo (shared with `halo todo` through ~/.halo/todo.json)
    func loadTodos(force: Bool = false) {
        let p = HALO_DIR + "/todo.json"
        let mt = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
        guard force || mt != todoMtime else { return }
        todoMtime = mt
        if let d = FileManager.default.contents(atPath: p), let t = try? JSONDecoder().decode([Todo].self, from: d) {
            if t != deck.todos { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { deck.todos = t } }
        } else if !FileManager.default.fileExists(atPath: p) { deck.todos = [] }
    }
    func saveTodos() {
        let p = HALO_DIR + "/todo.json"
        if let d = try? JSONEncoder().encode(deck.todos) { try? d.write(to: URL(fileURLWithPath: p)) }
        todoMtime = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
    }
    func addTodo(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !t.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { deck.todos.append(Todo(id: Int(Date().timeIntervalSince1970 * 1000), text: t, done: false, created: Date().timeIntervalSince1970)) }
        saveTodos()
    }
    func toggleTodo(_ t: Todo) { if let i = deck.todos.firstIndex(of: t) { withAnimation(.easeInOut(duration: 0.25)) { deck.todos[i].done.toggle() }; saveTodos() } }
    func removeTodo(_ t: Todo) { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { deck.todos.removeAll { $0.id == t.id } }; saveTodos() }
    func sendTodo(_ t: Todo, to s: Session) { runAsync(["halo", "send", s.id, t.text, "--no-wait"]) }

    // ---- live view of the Chrome window Claude is driving
    func chromeWindow() -> WinInfo? {
        let all = cgWindows(all: true)
        if let s = deck.sessions.first(where: { $0.owner == "Google Chrome" }), let w = s.window, let i = all.first(where: { $0.id == w }) { return i }
        return all.first { $0.owner == "Google Chrome" && $0.layer == 0 && $0.bounds.width > 300 && $0.bounds.height > 200 }
    }
    func liveCapture() {
        let recentChrome = deck.actions.first.map { $0.isChrome && Date().timeIntervalSince($0.time) < 120 } ?? false
        guard deck.tab == 2 || deck.liveWindowOpen || recentChrome else { return }
        liveTick += 1
        if !(deck.tab == 2 || deck.liveWindowOpen) && liveTick % 4 != 0 { return }   // background: 2 s cadence
        guard let w = chromeWindow() else { if deck.liveImage != nil { deck.liveImage = nil }; deck.liveTitle = "no Chrome window"; return }
        captureWindow(w.id) { [weak self] img in
            guard let img = img else { return }
            DispatchQueue.main.async { self?.deck.liveImage = img; self?.deck.liveTitle = w.name.isEmpty ? "Google Chrome" : w.name }
        }
    }
    func toggleLiveWindow() {
        if let w = liveWindow { w.orderOut(nil); liveWindow = nil; deck.liveWindowOpen = false; return }
        let scr = NSScreen.screens.first?.visibleFrame ?? .zero
        let f = NSRect(x: scr.midX - 460, y: scr.midY - 300, width: 920, height: 600)
        let w = KeyPanel(contentRect: f, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Live · Claude in Chrome"; w.titlebarAppearsTransparent = true; w.isOpaque = false; w.backgroundColor = NSColor(white: 0.06, alpha: 0.96)
        w.level = .floating; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LiveView(deck: deck, controller: self, big: true))
        w.orderFrontRegardless()
        liveWindow = w; deck.liveWindowOpen = true
    }

    func runHUDCommands() {
        let p = HALO_DIR + "/deck.cmd"
        guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: p)
        for line in s.split(separator: "\n") {
            let a = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let c = a.first else { continue }
            let arg = a.count > 1 ? a[1] : ""
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                switch c {
                case "tab": deck.tab = ["agents": 0, "files": 1, "live": 2, "todo": 3][arg] ?? 0
                case "select":
                    deck.tab = 1
                    if let f = deck.files.first(where: { $0.path == arg }) { deck.selected = f }
                    else {
                        let u = URL(fileURLWithPath: arg)
                        let m = (try? FileManager.default.attributesOfItem(atPath: arg)[.modificationDate] as? Date) ?? Date()
                        deck.selected = FileItem(path: arg, name: u.lastPathComponent, dir: u.deletingLastPathComponent().path, mtime: m)
                    }
                case "clean": deck.clean = arg == "on"
                case "connectors": deck.showConnectors = arg == "on"
                case "focus": setFocus(arg == "on", fromCLI: true)
                case "quit": NSApp.terminate(nil)
                default: break
                }
            }
        }
    }

    // 0.4 s: session metadata + state files
    func metaTick() {
        runHUDCommands()
        loadTodos()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: HALO_DIR) else { return }
        var seen: [String] = []
        var changed = false
        for n in names where n.hasSuffix(".json") && !["deck.json", "todo.json", "focus.json"].contains(n) {
            let name = String(n.dropLast(5)); seen.append(name)
            let p = HALO_DIR + "/" + n
            var s = deck.sessions.first { $0.id == name }
            if s == nil { s = Session(id: name); deck.sessions.append(s!); changed = true }
            let mt = (try? fm.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
            if metaMtimes[name] != mt, let d = fm.contents(atPath: p), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                metaMtimes[name] = mt
                s!.kind = j["kind"] as? String ?? "tmux"; s!.app = j["app"] as? String ?? ""
                s!.owner = j["owner"] as? String ?? "Terminal"; s!.cwd = j["cwd"] as? String ?? ""
                s!.cmd = j["cmd"] as? String ?? ""; s!.openedTs = j["opened_ts"] as? Double ?? 0
                if let w = j["window"] as? Int { s!.window = CGWindowID(w) }
                if let pid = j["pid"] as? Int { s!.pid = Int32(pid) }
            }
            if let st = try? String(contentsOfFile: HALO_DIR + "/" + name + ".state", encoding: .utf8) {
                let parts = st.split(separator: "\n").first.map(String.init)?.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                let state = parts.first ?? "idle", label = parts.count > 1 ? parts[1] : ""
                if s!.state != state { s!.state = state }
                if s!.label != label { s!.label = label }
            }
        }
        let before = deck.sessions.count
        deck.sessions.removeAll { !seen.contains($0.id) }
        if changed || deck.sessions.count != before { deck.objectWillChange.send() }
    }

    // 2 s: host + process + claude stats + files
    func statsTick() {
        let sessions = deck.sessions.map { ($0.id, $0.kind, $0.cwd, $0.pid, $0.openedTs, $0.isClaude) }
        let orchPid = deck.orch.pid, orchSession = deck.orchSession
        let cwds = Array(Set(sessions.map { $0.2 } + [deck.orch.cwd])).filter { !$0.isEmpty }
        statsQ.async { [self] in
            // host
            var cpuPct = 0.0
            if let now = cpuTicks(), let prev = prevTicks {
                let busy = Double((now.user - prev.user) + (now.sys - prev.sys) + (now.nice - prev.nice))
                let total = busy + Double(now.idle - prev.idle)
                cpuPct = total > 0 ? busy / total * 100 : 0
                prevTicks = now
            }
            let memGB = Double(memUsedBytes()) / 1_073_741_824
            var loads = [Double](repeating: 0, count: 3); getloadavg(&loads, 3)
            // processes
            let table = psTable()
            var cpuBy: [String: (Double, Double)] = [:]
            for (name, kind, _, pid, _, _) in sessions {
                var roots: [Int32] = []
                if kind == "tmux" {
                    roots = run(["tmux", "list-panes", "-t", "halo_" + name, "-F", "#{pane_pid}"]).split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                } else if let p = pid { roots = [p] }
                cpuBy[name] = treeSum(roots, table)
            }
            let orchStats = orchPid.map { treeSum([$0], table) }
            // claude status files: pair each agent with the transcript CREATED right after it opened
            // (agents in the same folder share a project dir, so cwd alone is ambiguous)
            let statuses = readStatusFiles()
            var statusBy: [String: StatusInfo] = [:]
            var tokBy: [String: (Int, Int)] = [:]
            var newActions: [AgentAction] = []
            var used = Set<String>()
            let claudeSessions = sessions.filter { $0.5 }.sorted { $0.4 < $1.4 }
            for (name, _, cwd, _, opened, _) in claudeSessions where !cwd.isEmpty {
                let dir = HOME + "/.claude/projects/" + cwd.replacingOccurrences(of: "/", with: "-")
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                var best: (String, Date)? = nil
                for n in names where n.hasSuffix(".jsonl") && !used.contains(n) && n != orchSession.map({ $0 + ".jsonl" }) {
                    let p = dir + "/" + n
                    let attrs = try? FileManager.default.attributesOfItem(atPath: p)
                    let born = (attrs?[.creationDate] as? Date) ?? .distantPast
                    if born.timeIntervalSince1970 >= opened - 3 && (best == nil || born < best!.1) { best = (n, born) }
                }
                guard let b = best else { continue }
                used.insert(b.0)
                let sid = String(b.0.dropLast(6))
                if let st = statuses.first(where: { $0.sessionId == sid }) { statusBy[name] = st }
                tokBy[name] = transcripts.totals(dir + "/" + b.0)
                newActions += transcripts.drainActions(dir + "/" + b.0, agent: name)
            }
            let orchStatus = orchSession.flatMap { sid in statuses.first { $0.sessionId == sid } }
            let orchTok = orchStatus?.transcript.map { transcripts.totals($0) }
            if let t = orchStatus?.transcript { newActions += transcripts.drainActions(t, agent: "you") }
            // files
            let files = recentFiles(in: cwds)

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.deck.cpuNow = cpuPct
                    self.deck.cpuHist.removeFirst(); self.deck.cpuHist.append(cpuPct)
                    self.deck.memUsedGB = memGB; self.deck.load1 = loads[0]
                    for s in self.deck.sessions {
                        if let c = cpuBy[s.id] { s.cpu = c.0; s.rssMB = c.1; s.cpuHist.removeFirst(); s.cpuHist.append(c.0) }
                        if let st = statusBy[s.id] { s.model = st.model; s.ctxPct = st.ctx; s.limit5h = st.l5; s.limit7d = st.l7; s.cost = st.cost }
                        if let t = tokBy[s.id] { s.tokIn = t.0; s.tokOut = t.1 }
                    }
                    if let o = orchStats { self.deck.orch.cpu = o.cpu; self.deck.orch.rssMB = o.rssMB; self.deck.orch.cpuHist.removeFirst(); self.deck.orch.cpuHist.append(o.cpu) }
                    if let st = orchStatus { self.deck.orch.model = st.model; self.deck.orch.ctxPct = st.ctx; self.deck.orch.limit5h = st.l5; self.deck.orch.limit7d = st.l7; self.deck.orch.cost = st.cost }
                    if let t = orchTok { self.deck.orch.tokIn = t.0; self.deck.orch.tokOut = t.1 }
                    self.deck.tokensTotalOut = self.deck.orch.tokOut + self.deck.sessions.reduce(0) { $0 + $1.tokOut }
                    if !newActions.isEmpty {
                        let fresh = newActions.sorted { $0.time > $1.time }
                        self.deck.actions = Array((fresh + self.deck.actions).prefix(60))
                        if self.deck.autoLive, fresh.contains(where: { $0.isChrome && Date().timeIntervalSince($0.time) < 30 }), self.deck.tab != 2, !self.deck.liveWindowOpen {
                            self.deck.tab = 2
                        }
                    }
                    if files != self.deck.files {
                        self.deck.files = files
                        if self.deck.selected == nil, let f = files.first { self.deck.selected = f }
                    }
                }
            }
        }
    }

    func quit() {
        if deck.focus || FileManager.default.fileExists(atPath: HALO_DIR + "/focus.json") { run(["halo", "full", "off"]) }   // never leave the Dock hidden
        NSApp.terminate(nil)
    }

    func setFocus(_ on: Bool, fromCLI: Bool = false) {
        deck.focus = on
        if on { deck.clean = true }
        // dock the sidebar edge-to-edge in focus mode, floating card otherwise
        let scr = NSScreen.screens.first
        let full = scr?.frame ?? .zero, vis = scr?.visibleFrame ?? .zero
        let f = on ? NSRect(x: full.maxX - HUD_WIDTH - 8, y: full.minY + 8, width: HUD_WIDTH, height: full.height - 16)
                   : NSRect(x: vis.maxX - HUD_WIDTH - 10, y: vis.minY + 10, width: HUD_WIDTH, height: vis.height - 20)
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.45; ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); hud.animator().setFrame(f, display: true) }
        if !fromCLI { runAsync(["halo", "full", on ? "on" : "off"]) }
    }

    // actions
    func open(kind: String) {
        switch kind {
        case "claude": runAsync(["halo", "open", "--cmd", "claude", "--cwd", deck.orch.cwd.isEmpty ? HOME : deck.orch.cwd])
        case "codex": runAsync(["halo", "open", "--cmd", "codex", "--cwd", deck.orch.cwd.isEmpty ? HOME : deck.orch.cwd])
        case "shell": runAsync(["halo", "open", "--shell", "--cwd", deck.orch.cwd.isEmpty ? HOME : deck.orch.cwd])
        default: runAsync(["halo", "open", "--app", kind, "--cwd", deck.orch.cwd.isEmpty ? HOME : deck.orch.cwd])
        }
    }
    func send(_ s: Session) {
        let text = s.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        s.prompt = ""
        runAsync(["halo", "send", s.id, text, "--settle", "3"])
    }
    func focus(_ s: Session) { runAsync(["halo", "focus", s.id]) }
    func close(_ s: Session) { runAsync(["halo", "close", s.id]) }
    func tile() { runAsync(["halo", "tile"]) }
    func openIn(_ app: String, _ path: String) { runAsync(app.isEmpty ? ["open", path] : ["open", "-a", app, path]) }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUD (SwiftUI) -------------------------------------------------------

func fmtTok(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.2fM", Double(n)/1e6) : n >= 1000 ? String(format: "%.1fk", Double(n)/1e3) : "\(n)"
}
func stateSwiftColor(_ s: String) -> Color { Color(cgColor: stateColor(s)) }

struct HUDView: View {
    @ObservedObject var deck: Deck
    let controller: DeckController
    var body: some View {
        VStack(spacing: 10) {
            header
            Picker("", selection: $deck.tab) {
                Text("Agents").tag(0); Text("Files").tag(1)
                Text(deck.actions.first.map { $0.isChrome && Date().timeIntervalSince($0.time) < 60 } == true ? "● Live" : "Live").tag(2)
                Text(deck.todos.filter { !$0.done }.isEmpty ? "To-do" : "To-do \(deck.todos.filter { !$0.done }.count)").tag(3)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14)
            if deck.dictation.listening || !deck.dictation.text.isEmpty { DictationBar(deck: deck, controller: controller) }
            if deck.tab == 0 {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        SessionCard(s: deck.orch, controller: controller, isOrch: true)
                        ForEach(deck.sessions) { s in
                            SessionCard(s: s, controller: controller, isOrch: false)
                                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.95))))
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 6)
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: deck.sessions.map { $0.id })
                }
                launchBar
            } else if deck.tab == 1 {
                FilesPanel(deck: deck, controller: controller)
            } else if deck.tab == 2 {
                LiveView(deck: deck, controller: controller, big: false)
            } else {
                TodoPanel(deck: deck, controller: controller)
            }
        }
        .padding(.top, 14).padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("HALO").font(.system(size: 20, weight: .black, design: .rounded)).tracking(3)
                Text("workspace").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Text("v" + VERSION).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                MicButton(deck: deck)
                Button { controller.setFocus(!deck.focus) } label: { Image(systemName: deck.focus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").foregroundStyle(deck.focus ? Color.orange : Color.white) }.help(deck.focus ? "leave focused workspace" : "focused full-screen workspace")
                Toggle(isOn: $deck.showConnectors) { Image(systemName: "arrow.triangle.branch") }.toggleStyle(.button).help("arrow connectors")
                Toggle(isOn: $deck.clean) { Image(systemName: "rectangle.dashed") }.toggleStyle(.button).help("clean backdrop")
                Toggle(isOn: $deck.autoTile) { Image(systemName: "rectangle.3.group") }.toggleStyle(.button).help("auto-align windows")
                Button { controller.tile() } label: { Image(systemName: "square.grid.2x2") }.help("tile windows")
                Button { controller.quit() } label: { Image(systemName: "xmark") }.help("quit deck")
            }.buttonStyle(.borderless).padding(.horizontal, 16)

            HStack(spacing: 12) {
                Chart(Array(deck.cpuHist.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("cpu", v))
                        .foregroundStyle(LinearGradient(colors: [Color.orange.opacity(0.55), Color.orange.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", i), y: .value("cpu", v))
                        .foregroundStyle(Color.orange).lineStyle(StrokeStyle(lineWidth: 1.6)).interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) { Image(systemName: "cpu").font(.system(size: 10)); Text(String(format: "%.0f%%", deck.cpuNow)).font(.system(size: 15, weight: .bold, design: .rounded)).contentTransition(.numericText()) }
                    Text(String(format: "%.1f / %.0f GB", deck.memUsedGB, deck.memTotalGB)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "load %.2f · %@ out", deck.load1, fmtTok(deck.tokensTotalOut))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                }.frame(width: 118)
            }.padding(.horizontal, 14)
        }
    }

    var launchBar: some View {
        VStack(spacing: 6) {
            Text("LAUNCH").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                LaunchMenu(title: "Claude", icon: "sparkles", tint: .orange, cli: "claude", app: "claude-app", controller: controller)
                LaunchMenu(title: "Codex", icon: "terminal", tint: .green, cli: "codex", app: "codex-app", controller: controller)
                LaunchButton(title: "Antigravity", icon: "wand.and.stars", tint: .purple) { controller.open(kind: "antigravity") }
                LaunchButton(title: "Chrome", icon: "globe", tint: .blue) { controller.open(kind: "chrome") }
            }
            HStack(spacing: 6) {
                LaunchButton(title: "Cursor", icon: "cursorarrow.rays", tint: .cyan) { controller.open(kind: "cursor") }
                LaunchButton(title: "VS Code", icon: "chevron.left.forwardslash.chevron.right", tint: .indigo) { controller.open(kind: "vscode") }
                LaunchButton(title: "Shell", icon: "apple.terminal", tint: .gray) { controller.open(kind: "shell") }
            }
        }.padding(.horizontal, 14)
    }
}

struct LaunchMenu: View {
    let title: String, icon: String, tint: Color, cli: String, app: String
    let controller: DeckController
    @State private var hover = false
    var body: some View {
        Menu {
            Button { controller.open(kind: cli) } label: { Label("CLI · in a halo terminal (prompt injection + output)", systemImage: "terminal") }
            Button { controller.open(kind: app) } label: { Label("App · desktop window (paste injection + screenshots)", systemImage: "macwindow") }
        } label: {
            HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 10, weight: .semibold)); Text(title).font(.system(size: 11, weight: .semibold)); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7) }
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(hover ? 0.42 : 0.22)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.5), lineWidth: 1))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
    }
}

struct LaunchButton: View {
    let title: String, icon: String, tint: Color, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 10, weight: .semibold)); Text(title).font(.system(size: 11, weight: .semibold)) }
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(hover ? 0.42 : 0.22)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.5), lineWidth: 1))
                .scaleEffect(hover ? 1.03 : 1)
        }.buttonStyle(.plain).onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
    }
}

struct SessionCard: View {
    @ObservedObject var s: Session
    let controller: DeckController
    let isOrch: Bool
    @State private var pulse = false

    var tint: Color { stateSwiftColor(s.state) }
    var kindLabel: String { isOrch ? "orchestrator" : s.kind == "app" ? s.app : (s.cmd.isEmpty ? "shell" : s.cmd) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 9, height: 9)
                    .shadow(color: tint.opacity(0.9), radius: pulse ? 7 : 2)
                    .scaleEffect(s.state == "active" && pulse ? 1.25 : 1)
                Text(isOrch ? "you" : s.name).font(.system(size: 13, weight: .bold, design: .rounded))
                Text(kindLabel).font(.system(size: 9.5, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.1)))
                if !s.onScreen && s.window != nil { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).help("on another Space") }
                Spacer()
                Chart(Array(s.cpuHist.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("t", i), y: .value("cpu", v)).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.2)).interpolationMethod(.catmullRom)
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...max(50, (s.cpuHist.max() ?? 0) * 1.2)).frame(width: 54, height: 16)
                Text(String(format: "%.0f%%", s.cpu)).font(.system(size: 12, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text(String(format: "%.0f MB", s.rssMB)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).contentTransition(.numericText())
            }
            Text(s.label.isEmpty ? s.state : s.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            if s.isClaude {
                HStack(spacing: 10) {
                    MiniGauge(value: s.ctxPct, title: "ctx", tint: .cyan)
                    MiniGauge(value: s.limit5h, title: "5h", tint: .orange)
                    MiniGauge(value: s.limit7d, title: "7d", tint: .pink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.model.isEmpty ? "—" : s.model).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        Text("\(fmtTok(s.tokIn)) in · \(fmtTok(s.tokOut)) out").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).contentTransition(.numericText())
                        if let c = s.cost { Text(String(format: "$%.2f", c)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6)) }
                    }
                    Spacer(minLength: 0)
                }
            }
            if !isOrch {
                HStack(spacing: 6) {
                    TextField(s.kind == "tmux" ? "prompt…" : "inject into \(s.app)…", text: $s.prompt, onCommit: { controller.send(s) })
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                    IconButton("paperplane.fill", tint: .orange) { controller.send(s) }
                    if s.kind == "tmux" {
                        IconButton("doc.on.doc", tint: .teal) { runAsync(["halo", "copy", s.id]) }.help("copy last answer (clean text)")
                        IconButton("doc.on.clipboard", tint: .mint) { runAsync(["halo", "paste", s.id, "--no-wait"]) }.help("send clipboard as prompt")
                    }
                    IconButton("scope", tint: .blue) { controller.focus(s) }
                    IconButton("xmark.circle", tint: .red) { controller.close(s) }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(s.state == "active" ? 0.6 : 0.25), lineWidth: 1))
        .animation(.easeInOut(duration: 0.4), value: s.state)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

struct IconButton: View {
    let icon: String, tint: Color, action: () -> Void
    @State private var hover = false
    init(_ icon: String, tint: Color, action: @escaping () -> Void) { self.icon = icon; self.tint = tint; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(hover ? 0.45 : 0.2)))
        }.buttonStyle(.plain).onHover { hover = $0 }.animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct MiniGauge: View {
    let value: Double?, title: String, tint: Color
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 3.5)
                Circle().trim(from: 0, to: CGFloat(min(max((value ?? 0) / 100, 0), 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value ?? 0)
                Text(value.map { String(format: "%.0f", $0) } ?? "–").font(.system(size: 9, weight: .bold, design: .rounded))
            }.frame(width: 30, height: 30)
            Text(title).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
        }
    }
}

// MARK: dictation (on-device speech, like a push-to-talk) ----------------------

final class Dictation: ObservableObject {
    @Published var listening = false
    @Published var text = ""
    @Published var level: CGFloat = 0
    @Published var status = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer()

    func toggle() { listening ? stop() : start() }

    func start() {
        status = "requesting mic…"
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            guard ok else { DispatchQueue.main.async { self.status = "microphone denied (System Settings → Privacy)" }; return }
            SFSpeechRecognizer.requestAuthorization { auth in
                DispatchQueue.main.async {
                    guard auth == .authorized else { self.status = "speech recognition denied"; return }
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        text = ""; status = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
            if let ch = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength); var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                DispatchQueue.main.async { self?.level = CGFloat(min(1, rms * 12)) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { status = "audio engine failed"; return }
        listening = true
        task = recognizer?.recognitionTask(with: req) { [weak self] res, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let r = res { self.text = r.bestTranscription.formattedString }
                if err != nil || res?.isFinal == true { self.finish() }
            }
        }
    }

    func stop() { request?.endAudio(); finish() }

    private func finish() {
        guard listening else { return }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        task?.finish(); task = nil; request = nil
        listening = false; level = 0
    }
    func clear() { text = ""; status = "" }
}

struct MicButton: View {
    @ObservedObject var deck: Deck
    @ObservedObject var d: Dictation
    init(deck: Deck) { self.deck = deck; self.d = deck.dictation }
    var body: some View {
        Button { d.toggle() } label: {
            ZStack {
                if d.listening { Circle().fill(Color.red.opacity(0.35)).frame(width: 22 + d.level * 22, height: 22 + d.level * 22).animation(.easeOut(duration: 0.08), value: d.level) }
                Image(systemName: d.listening ? "mic.fill" : "mic").foregroundStyle(d.listening ? Color.red : Color.white)
            }.frame(width: 26, height: 26)
        }.help(d.listening ? "stop dictation" : "dictate (on-device speech)")
    }
}

struct DictationBar: View {
    @ObservedObject var deck: Deck
    @ObservedObject var d: Dictation
    let controller: DeckController
    init(deck: Deck, controller: DeckController) { self.deck = deck; self.d = deck.dictation; self.controller = controller }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(d.listening ? Color.red : Color.orange)
                Text(d.listening ? "listening…" : "transcript").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                if !d.status.isEmpty { Text(d.status).font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                if !d.listening && !d.text.isEmpty {
                    IconButton("doc.on.doc", tint: .teal) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(d.text, forType: .string) }.help("copy")
                    IconButton("checklist", tint: .purple) { controller.addTodo(d.text); d.clear() }.help("add as to-do")
                    Menu { ForEach(deck.sessions) { s in Button("→ \(s.name)") { runAsync(["halo", "send", s.id, d.text, "--no-wait"]); d.clear() } } }
                        label: { Image(systemName: "paperplane.fill").frame(width: 26, height: 24).background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.3))) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30).help("send to an agent")
                    IconButton("xmark", tint: .gray) { d.clear() }
                }
            }
            Text(d.text.isEmpty ? "…" : d.text).font(.system(size: 12)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity).animation(.easeInOut(duration: 0.15), value: d.text)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke((d.listening ? Color.red : Color.orange).opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: live view -------------------------------------------------------------

struct LiveView: View {
    @ObservedObject var deck: Deck
    let controller: DeckController
    let big: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(deck.liveImage == nil ? Color.gray : Color.red).frame(width: 7, height: 7)
                Text(deck.liveTitle.isEmpty ? "Claude in Chrome" : deck.liveTitle).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Spacer()
                Toggle(isOn: $deck.autoLive) { Image(systemName: "bolt.badge.automatic") }.toggleStyle(.button).help("jump to Live when Chrome actions happen")
                if !big { Button { controller.toggleLiveWindow() } label: { Image(systemName: deck.liveWindowOpen ? "pip.exit" : "pip.enter") }.help("pop out live window") }
            }.buttonStyle(.borderless).padding(.horizontal, 14)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.45))
                if let img = deck.liveImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10)).padding(4)
                        .transition(.opacity).id(img.size.width)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "globe").font(.system(size: 26)).foregroundStyle(.white.opacity(0.3))
                        Text("waiting for a Chrome window").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }.frame(maxWidth: .infinity).frame(height: big ? 380 : 210).padding(.horizontal, 14)
            .animation(.easeInOut(duration: 0.25), value: deck.liveImage == nil)
            Text("ACTIONS").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    if deck.actions.isEmpty { Text("no tool actions yet — they appear here as agents work (Chrome actions highlighted)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.top, 8) }
                    ForEach(deck.actions) { a in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: a.isChrome ? "globe" : "wrench.and.screwdriver").font(.system(size: 10)).foregroundStyle(a.isChrome ? Color.blue : Color.white.opacity(0.5)).frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(a.tool.replacingOccurrences(of: "chrome:", with: "")).font(.system(size: 11, weight: .bold))
                                    Text(a.agent).font(.system(size: 9.5, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.white.opacity(0.1)))
                                    Spacer()
                                    Text(a.time, style: .time).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                                }
                                if !a.summary.isEmpty { Text(a.summary).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.65)).lineLimit(2) }
                            }
                        }.padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(a.isChrome ? Color.blue.opacity(0.14) : .white.opacity(0.04)))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }.padding(.horizontal, 14)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: deck.actions.map { $0.id })
            }
        }
    }
}

// MARK: to-do panel -----------------------------------------------------------

struct TodoPanel: View {
    @ObservedObject var deck: Deck
    let controller: DeckController
    @State private var draft = ""
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("add a feature, command or instruction…", text: $draft, onCommit: { controller.addTodo(draft); draft = "" })
                    .textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.08)))
                IconButton("plus", tint: .purple) { controller.addTodo(draft); draft = "" }
            }.padding(.horizontal, 14)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    if deck.todos.isEmpty { Text("empty — type above, dictate with the mic, or `halo todo add \"…\"`").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.top, 10) }
                    ForEach(deck.todos) { t in
                        HStack(alignment: .top, spacing: 8) {
                            Button { controller.toggleTodo(t) } label: {
                                Image(systemName: t.done ? "checkmark.circle.fill" : "circle").font(.system(size: 15)).foregroundStyle(t.done ? Color.green : Color.white.opacity(0.6))
                            }.buttonStyle(.plain)
                            Text(t.text).font(.system(size: 12)).strikethrough(t.done, color: .white.opacity(0.5)).foregroundStyle(t.done ? .white.opacity(0.45) : .white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Menu { ForEach(deck.sessions) { s in Button("→ \(s.name)") { controller.sendTodo(t, to: s) } } }
                                label: { Image(systemName: "paperplane").font(.system(size: 11)).frame(width: 22, height: 22) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("send to an agent as a prompt")
                            Button { controller.removeTodo(t) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).frame(width: 18, height: 22) }.buttonStyle(.plain)
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(t.done ? .white.opacity(0.03) : .white.opacity(0.07)))
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                }.padding(.horizontal, 14)
            }
            if deck.todos.contains(where: { $0.done }) {
                Button("clear completed") { withAnimation { deck.todos.removeAll { $0.done } }; controller.saveTodos() }.font(.system(size: 10.5)).buttonStyle(.borderless).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

// MARK: files panel -----------------------------------------------------------

struct FilesPanel: View {
    @ObservedObject var deck: Deck
    let controller: DeckController
    var body: some View {
        VStack(spacing: 8) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    if deck.files.isEmpty { Text("no recent edits in the agents' folders").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.top, 12) }
                    ForEach(deck.files) { f in
                        Button { deck.selected = f } label: {
                            HStack(spacing: 8) {
                                Image(systemName: f.isPDF ? "doc.richtext" : "doc.text").font(.system(size: 11)).foregroundStyle(f.isPDF ? .pink : .cyan)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                    Text(f.dir.isEmpty ? "/" : f.dir).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                }
                                Spacer()
                                Text(f.mtime, style: .relative).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
                            }.padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9).fill(deck.selected == f ? .white.opacity(0.14) : .white.opacity(0.04)))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 14)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: deck.files.map { $0.path })
            }.frame(maxHeight: 190)
            Divider().overlay(.white.opacity(0.15)).padding(.horizontal, 14)
            if let f = deck.selected {
                HStack(spacing: 6) {
                    Text(f.name).font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                    Spacer()
                    Text("open in").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                    IconButton("cursorarrow.rays", tint: .cyan) { controller.openIn("Cursor", f.path) }.help("Cursor")
                    IconButton("chevron.left.forwardslash.chevron.right", tint: .indigo) { controller.openIn("Visual Studio Code", f.path) }.help("VS Code")
                    IconButton("wand.and.stars", tint: .purple) { controller.openIn("Antigravity", f.path) }.help("Antigravity")
                    IconButton("arrow.up.forward.app", tint: .gray) { controller.openIn("", f.path) }.help("default app")
                }.padding(.horizontal, 14)
                if f.isPDF { PDFLiveView(path: f.path).id(f.path).padding(.horizontal, 14) }
                else { TextLiveEditor(path: f.path).id(f.path).padding(.horizontal, 14) }
            } else { Spacer() }
        }
    }
}

/// PDFKit view that reloads when the file changes, keeping page + scroll.
struct PDFLiveView: NSViewRepresentable {
    let path: String
    func makeCoordinator() -> Coord { Coord() }
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true; v.displayMode = .singlePageContinuous; v.backgroundColor = NSColor(white: 0.08, alpha: 1)
        v.document = PDFDocument(url: URL(fileURLWithPath: path))
        context.coordinator.start(path: path, view: v)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {}
    static func dismantleNSView(_ v: PDFView, coordinator: Coord) { coordinator.timer?.invalidate() }
    final class Coord {
        var timer: Timer?; var mtime: Date = .distantPast
        func start(path: String, view: PDFView) {
            mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self, weak view] _ in
                guard let self = self, let view = view else { return }
                let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                guard m != self.mtime else { return }
                self.mtime = m
                let page = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
                let scroll = (view.documentView?.enclosingScrollView?.contentView.bounds.origin) ?? .zero
                guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return }
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; view.animator().alphaValue = 0.35 } completionHandler: {
                    view.document = doc
                    if let p = doc.page(at: min(page, doc.pageCount - 1)) { view.go(to: p) }
                    view.documentView?.enclosingScrollView?.contentView.scroll(to: scroll)
                    NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.3; view.animator().alphaValue = 1 }
                }
            }
        }
    }
}

/// Editable text view that follows external edits until you start typing; ⌘S / Save writes back.
struct TextLiveEditor: View {
    let path: String
    @State private var text = ""
    @State private var dirty = false
    @State private var mtime = Date.distantPast
    @State private var flash = false
    let timer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(flash ? 0.55 : 0.35)))
                .onChange(of: text) { _ in if !loading { dirty = true } }
            HStack {
                Text(dirty ? "edited · unsaved" : "live · follows agent edits").font(.system(size: 9.5)).foregroundStyle(dirty ? .orange : .white.opacity(0.45))
                Spacer()
                if dirty {
                    Button("Revert") { load() }.font(.system(size: 10.5))
                    Button("Save") { save() }.font(.system(size: 10.5, weight: .bold)).keyboardShortcut("s", modifiers: .command)
                }
            }.buttonStyle(.borderless)
        }
        .onAppear { load() }
        .onReceive(timer) { _ in
            let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            if m != mtime && !dirty { load(); withAnimation(.easeOut(duration: 0.2)) { flash = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { flash = false } } }
        }
    }
    @State private var loading = false
    func load() {
        loading = true
        mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let d = FileManager.default.contents(atPath: path), d.count < 1_500_000 { text = String(decoding: d, as: UTF8.self) } else { text = "(file too large or unreadable)" }
        dirty = false
        DispatchQueue.main.async { loading = false }
    }
    func save() {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        dirty = false
    }
}

// MARK: - main ----------------------------------------------------------------

var orchArg: CGWindowID? = nil, orchSessionArg: String? = nil, cleanArg = false, focusArg = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--orch": if let v = it.next(), let n = UInt32(v) { orchArg = n }
    case "--orch-session": orchSessionArg = it.next()
    case "--clean": cleanArg = true
    case "--focus": focusArg = true
    default: break
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = DeckController(orch: orchArg, orchSession: orchSessionArg, clean: cleanArg)
try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: HALO_DIR + "/deck.pid", atomically: true, encoding: .utf8)
if focusArg { controller.setFocus(true, fromCLI: true) }
signal(SIGTERM) { _ in
    if FileManager.default.fileExists(atPath: HALO_DIR + "/focus.json") { run(["halo", "full", "off"]) }
    exit(0)
}
app.run()
