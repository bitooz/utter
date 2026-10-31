import AppKit
import QuartzCore

/// The pill at the bottom of the screen, without words: a waveform that follows the voice while listening (a lock beside
/// it when hands-free), a slow wave of dots while writing, and for a moment after, a symbol for anything worth knowing
/// (copied, failed…), which VoiceOver reads out as a sentence. Every size and fade is a spring stepped once per display
/// frame, so a change of state mid-animation carries on from where it is. Never takes focus or clicks.
final class HUD: NSObject {
    enum State: Equatable {
        case hidden
        case listening
        /// Listening without the key held.
        case handsFree
        case transcribing
        case notice(Notice)
    }

    enum Notice: CaseIterable {
        case copied, copiedFocusMoved, partMissing, failed, notPasted, noSpeech, cancelled, needsKey, micUnavailable

        var symbol: String {
            switch self {
            case .copied, .copiedFocusMoved: "doc.on.clipboard.fill"
            case .partMissing, .failed: "exclamationmark.triangle.fill"
            case .notPasted: "hand.raised.fill"
            case .noSpeech: "waveform.slash"
            case .cancelled: "xmark"
            case .needsKey: "key.fill"
            case .micUnavailable: "mic.slash.fill"
            }
        }

        /// The symbol's color, and a faint wash of it over the pill. None for the quiet ones.
        var tint: NSColor? {
            switch self {
            case .copied, .copiedFocusMoved: .systemBlue
            case .partMissing, .notPasted, .needsKey: .systemOrange
            case .failed, .micUnavailable: .systemRed
            case .noSpeech, .cancelled: nil
            }
        }

        /// What VoiceOver says, and what the pill would have said in words.
        var sentence: String {
            switch self {
            case .copied: "Copied to clipboard"
            case .copiedFocusMoved: "Copied, not pasted: focus moved"
            case .partMissing: "Part missing. Retry in the menu"
            case .failed: "Transcription failed. Retry in the menu"
            case .notPasted: "Not pasted: focus moved"
            case .noSpeech: "Didn't catch that"
            case .cancelled: "Cancelled"
            case .needsKey: "Add your OpenRouter key in Settings"
            case .micUnavailable: "Microphone unavailable"
            }
        }

        /// Problems stay up longer than news.
        var seconds: Double {
            switch self {
            case .failed, .partMissing, .needsKey, .micUnavailable, .notPasted: 3.5
            default: 1.8
            }
        }
    }

    // Sizes, in points.
    static let height: CGFloat = 32
    static let bars = 9
    static let barWidth: CGFloat = 3
    static let dot: CGFloat = 3       // a bar at rest
    static let tallest: CGFloat = 18
    static let padding: CGFloat = 15
    static let lockRoom: CGFloat = 20  // the lock and the space after it
    static let noticeWidth: CGFloat = 48
    static let canvas = CGSize(width: 240, height: 84) // the panel: room for the pill, its shadow and a bounce

    private(set) var state: State = .hidden
    /// The panel and its layers, for `--capture-hud`.
    let root = CALayer()
    private let onScreen: Bool
    private let panel: NSPanel
    private let pill = CALayer()
    private let clip = CALayer() // the pill's inside: nothing shows past its edge while it changes size
    private let wash = CALayer()
    private let lock = CALayer()
    private let icon = CALayer()
    private var barLayers: [CALayer] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var hideWork: DispatchWorkItem?

    // Springs: response (s) and bounce (0 = none). Restrained: a few percent past the target at most.
    private var width = Spring(height, response: 0.42, bounce: 0.22)
    private var tall = Spring(height, response: 0.42, bounce: 0.22)
    private var scale = Spring(0.8, response: 0.4, bounce: 0.2)
    private var alpha = Spring(0, response: 0.2, bounce: 0)
    private var lift = Spring(0, response: 0.45, bounce: 0.1)
    private var gap = Spring(3, response: 0.4, bounce: 0.08)
    private var barsAlpha = Spring(0, response: 0.2, bounce: 0)
    private var lockAlpha = Spring(0, response: 0.3, bounce: 0)
    private var iconAlpha = Spring(0, response: 0.22, bounce: 0)
    private var iconScale = Spring(1, response: 0.38, bounce: 0.3)
    private var washAlpha = Spring(0, response: 0.35, bounce: 0)

    // The voice, and each bar's height and brightness (eased toward a target every frame).
    private var rawLevel: CGFloat = 0
    private var voice: CGFloat = 0
    private var history: [(t: Double, v: CGFloat)] = []
    private var barHeight = [CGFloat](repeating: dot, count: bars)
    private var barAlpha = [CGFloat](repeating: 1, count: bars)
    private var clock: Double = 0
    private var noticeAt: Double = 0
    private var noticeTinted = false
    /// How much each bar takes of the voice: uneven, like a real waveform.
    private static let reach: [CGFloat] = [0.5, 0.74, 0.6, 0.9, 1, 0.84, 0.66, 0.8, 0.48]
    private let wobble: [(speed: Double, phase: Double)] = (0..<HUD.bars).map { (i: Int) -> (speed: Double, phase: Double) in
        (speed: 7 + Double((i * 5) % 7), phase: Double(i) * 1.7)
    }

    /// Called after each frame is laid out (`--capture-hud` records it).
    var onFrame: (() -> Void)?

    /// `onScreen: false` keeps the panel out of sight and the display link off: the caller steps it with `advance`.
    init(onScreen: Bool = true) {
        self.onScreen = onScreen
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.canvas),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the pill draws its own, so it follows the pill's shape as it changes
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setAccessibilityElement(false)

        root.frame = CGRect(origin: .zero, size: Self.canvas)
        pill.backgroundColor = NSColor(white: 0.035, alpha: 1).cgColor
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOffset = CGSize(width: 0, height: -4)
        pill.shadowRadius = 12
        pill.borderWidth = 0.5
        root.addSublayer(pill)
        clip.masksToBounds = true
        pill.addSublayer(clip)
        clip.addSublayer(wash)
        for _ in 0..<Self.bars {
            let b = CALayer()
            b.backgroundColor = NSColor.white.cgColor
            b.cornerRadius = Self.barWidth / 2
            clip.addSublayer(b)
            barLayers.append(b)
        }
        lock.contentsGravity = .center
        setImage(lock, "lock.fill", size: 10, color: NSColor(white: 1, alpha: 0.75))
        clip.addSublayer(lock)
        icon.contentsGravity = .center
        clip.addSublayer(icon)
        for l in [root, pill, clip, wash, lock, icon] + barLayers { l.actions = Self.noActions }

        let view = NSView(frame: root.frame)
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view
        if onScreen {
            let l = view.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            l.isPaused = true
            link = l
        }
        layout()
    }

    private static let noActions: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
        "opacity": NSNull(), "cornerRadius": NSNull(), "shadowPath": NSNull(), "contents": NSNull(), "backgroundColor": NSNull(),
        "borderColor": NSNull(), "shadowOpacity": NSNull(), "hidden": NSNull(), "frame": NSNull()]

    // MARK: State

    func set(_ new: State) {
        hideWork?.cancel()
        let wasHidden = state == .hidden
        guard new != state || { if case .notice = new { return true }; return false }() else { return }
        state = new
        // Back before the last one finished fading: carry on from where it is.
        if new != .hidden && wasHidden && alpha.value < 0.02 { appear() }

        switch new {
        case .hidden:
            alpha.target = 0; scale.target = 0.86; lift.target = -3
            width.target = Self.height
        case .listening, .handsFree:
            pillTargets(gap: 3, lock: new == .handsFree)
            barsAlpha.target = 1; iconAlpha.target = 0; washAlpha.target = 0
        case .transcribing:
            pillTargets(gap: 2.2, lock: false)
            barsAlpha.target = 1; iconAlpha.target = 0; washAlpha.target = 0
        case .notice(let n):
            width.target = Self.noticeWidth; tall.target = Self.height
            alpha.target = 1; scale.target = 1; lift.target = 0
            lockAlpha.target = 0; barsAlpha.target = 0
            setImage(icon, n.symbol, size: 14, color: n.tint ?? NSColor(white: 1, alpha: 0.82))
            wash.backgroundColor = Self.onDark(n.tint ?? .clear).cgColor
            noticeAt = clock; noticeTinted = n.tint != nil
            iconAlpha.target = 0 // `advance` brings the symbol in once the bars have gone
            iconScale.value = 0.5; iconScale.target = 1 // a small pop each time
            if onScreen { // off screen (`--capture-hud`, tests), the caller decides when it goes
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: n.sentence, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                let w = DispatchWorkItem { [weak self] in self?.set(.hidden) }
                hideWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + n.seconds, execute: w)
            }
        }
        if onScreen { link?.isPaused = false }
    }

    /// The input level in dBFS, as it comes in.
    func level(_ db: Double) { rawLevel = CGFloat(max(0, min(1, (db + 55) / 34))) }

    private func pillTargets(gap g: CGFloat, lock withLock: Bool) {
        gap.target = g
        lockAlpha.target = withLock ? 1 : 0
        width.target = Self.padding * 2 + Self.groupWidth(gap: g) + (withLock ? Self.lockRoom : 0)
        tall.target = Self.height
        alpha.target = 1; scale.target = 1; lift.target = 0
    }

    private static func groupWidth(gap: CGFloat) -> CGFloat { CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap }

    /// From nothing: a dot that grows into the pill while it rises and fades in.
    private func appear() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        pill.borderColor = NSColor(white: 1, alpha: dark ? 0.14 : 0.05).cgColor
        pill.shadowOpacity = dark ? 0.5 : 0.28
        width = width.reset(Self.height); tall = tall.reset(Self.height)
        scale = scale.reset(0.8); alpha = alpha.reset(0); lift = lift.reset(-8)
        lockAlpha = lockAlpha.reset(0); iconAlpha = iconAlpha.reset(0); barsAlpha = barsAlpha.reset(0); washAlpha = washAlpha.reset(0)
        barHeight = [CGFloat](repeating: Self.dot, count: Self.bars)
        voice = 0; rawLevel = 0; history = []
        guard onScreen else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            // The pill's middle 42 pt above the Dock (or the screen's edge), where the old pill sat.
            panel.setFrameOrigin(NSPoint(x: (vf.midX - Self.canvas.width / 2).rounded(), y: (vf.minY + 42 - Self.canvas.height / 2).rounded()))
        }
        lastTick = 0
        layout()
        panel.orderFrontRegardless()
    }

    // MARK: Frames

    @objc private func tick(_ l: CADisplayLink) {
        let dt = lastTick == 0 ? 1 / 60 : min(l.timestamp - lastTick, 1 / 20)
        lastTick = l.timestamp
        advance(dt)
        if state == .hidden && alpha.value < 0.01 && alpha.velocity.magnitude < 0.05 {
            panel.orderOut(nil)
            l.isPaused = true
            lastTick = 0
        }
    }

    /// Moves every spring and bar on by `dt` seconds and lays the layers out.
    func advance(_ dt: Double) {
        clock += dt
        let d = CGFloat(dt)
        for s in [\HUD.width, \.tall, \.scale, \.alpha, \.lift, \.gap, \.barsAlpha, \.lockAlpha, \.iconAlpha, \.iconScale, \.washAlpha] as [ReferenceWritableKeyPath<HUD, Spring>] {
            self[keyPath: s].step(d)
        }
        if case .notice = state {
            // The symbol after the bars are mostly gone; a brief wash of its color that settles to a faint one.
            let since = clock - noticeAt
            if since > 0.1 { iconAlpha.target = 1 }
            washAlpha.target = noticeTinted ? (since < 0.4 ? 0.26 : 0.1) : 0
        }
        // The voice: up fast, down slower, so syllables read as beats rather than flicker.
        voice += (rawLevel - voice) * (1 - exp(-d / (rawLevel > voice ? 0.035 : 0.14)))
        history.append((clock, voice))
        if history.count > 40 { history.removeFirst(history.count - 40) }

        let mid = CGFloat(Self.bars - 1) / 2
        for i in 0..<Self.bars {
            let from = abs(CGFloat(i) - mid)
            var target: CGFloat, bright: CGFloat
            switch state {
            case .transcribing:
                // A slow swell travelling left to right.
                let s = 0.5 + 0.5 * sin(2 * .pi * clock / 1.5 - Double(i) * 0.62)
                target = Self.dot + 4 * CGFloat(s * s)
                bright = 0.35 + 0.6 * CGFloat(s)
            case .listening, .handsFree:
                // Newest sound in the middle, rippling out to the edges; a soft idle shimmer when quiet.
                let v = voice(at: clock - Double(from) * 0.06)
                let w = 0.72 + 0.28 * CGFloat(sin(clock * wobble[i].speed + wobble[i].phase))
                let shape = Self.reach[i]
                let idle = 0.05 + 0.03 * CGFloat(sin(clock * 2.4 + Double(i) * 0.9))
                target = Self.dot + (Self.tallest - Self.dot) * min(1, max(pow(v, 0.75) * shape * w, idle))
                bright = 0.95
            default:
                target = Self.dot
                bright = barAlpha[i]
            }
            barHeight[i] += (target - barHeight[i]) * (1 - exp(-d / (target > barHeight[i] ? 0.045 : 0.09)))
            barAlpha[i] += (bright - barAlpha[i]) * (1 - exp(-d / 0.12))
        }
        layout()
        onFrame?()
    }

    /// The smoothed voice level as it was at time `t` (a little in the past).
    private func voice(at t: Double) -> CGFloat {
        guard let last = history.last else { return 0 }
        if t >= last.t { return last.v }
        for k in stride(from: history.count - 1, to: 0, by: -1) where history[k - 1].t <= t {
            let a = history[k - 1], b = history[k]
            return a.v + (b.v - a.v) * CGFloat((t - a.t) / max(b.t - a.t, 1e-6))
        }
        return history.first!.v
    }

    private func layout() {
        let w = max(width.value, 1), h = max(tall.value, 1)
        pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        pill.position = CGPoint(x: Self.canvas.width / 2, y: Self.canvas.height / 2 + lift.value)
        pill.cornerRadius = h / 2
        pill.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        pill.opacity = Float(max(0, min(1, alpha.value)))
        pill.transform = CATransform3DMakeScale(scale.value, scale.value, 1)
        clip.frame = pill.bounds
        clip.cornerRadius = h / 2
        wash.frame = pill.bounds
        wash.cornerRadius = h / 2
        wash.opacity = Float(max(0, washAlpha.value))

        let lockShare = max(0, min(1, lockAlpha.value))
        let group = Self.groupWidth(gap: gap.value)
        let left = (w - group - Self.lockRoom * lockShare) / 2
        lock.bounds = CGRect(x: 0, y: 0, width: 12, height: 14)
        lock.position = CGPoint(x: left + 6, y: h / 2)
        lock.opacity = Float(lockShare)
        lock.transform = CATransform3DMakeScale(0.6 + 0.4 * lockShare, 0.6 + 0.4 * lockShare, 1)
        let barsShare = max(0, min(1, barsAlpha.value))
        // While the pill grows out of a dot, the bars wait until there's room for them.
        let room = width.target > h + 1 ? max(0, min(1, (w - h) / (width.target - h) * 2 - 1)) : 1
        var x = left + Self.lockRoom * lockShare
        for (i, b) in barLayers.enumerated() {
            let bh = barHeight[i] * (0.4 + 0.6 * barsShare)
            b.frame = CGRect(x: x, y: (h - bh) / 2, width: Self.barWidth, height: bh)
            b.opacity = Float(barAlpha[i] * barsShare * barsShare * room)
            x += Self.barWidth + gap.value
        }
        icon.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        icon.position = CGPoint(x: w / 2, y: h / 2)
        icon.opacity = Float(max(0, min(1, iconAlpha.value)))
        icon.transform = CATransform3DMakeScale(iconScale.value, iconScale.value, 1)
    }

    // MARK: Drawing

    private func setImage(_ layer: CALayer, _ name: String, size: CGFloat, color: NSColor) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let c = Self.onDark(color)
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        // The symbol's shape filled with the color, so its cut-outs (the ! in a triangle) stay see-through.
        let image = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            c.set()
            r.fill(using: .sourceAtop)
            return true
        }
        layer.contentsScale = max(scale, 2)
        layer.contents = image.layerContents(forContentsScale: layer.contentsScale)
    }

    /// A system color as it looks on the dark pill, whatever the Mac's appearance.
    private static func onDark(_ c: NSColor) -> NSColor {
        var out = c
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB) ?? c }
        return out
    }

    // MARK: For tests

    var pillSize: CGSize { CGSize(width: width.value, height: tall.value) }
    var pillOpacity: CGFloat { alpha.value }
    var pillTargetWidth: CGFloat { width.target }
}

/// A damped spring, stepped in small slices so it is stable at any frame rate.
struct Spring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    let stiffness: CGFloat
    let damping: CGFloat

    /// `response`: about how long one swing takes, in seconds. `bounce`: 0 settles without passing the target.
    init(_ v: CGFloat, response: CGFloat, bounce: CGFloat) {
        value = v; target = v
        let w = 2 * .pi / response
        stiffness = w * w
        damping = 2 * (1 - bounce) * w
    }

    mutating func step(_ dt: CGFloat) {
        var left = dt
        while left > 0 {
            let h = min(left, 1 / 240)
            velocity += (stiffness * (target - value) - damping * velocity) * h
            value += velocity * h
            left -= h
        }
    }

    /// The same spring, still, at `v`.
    func reset(_ v: CGFloat) -> Spring { var s = self; s.value = v; s.target = v; s.velocity = 0; return s }
}
