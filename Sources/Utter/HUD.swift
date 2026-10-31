import AppKit

/// Small pill at the bottom of the screen showing what Utter is doing. Never takes focus or clicks.
final class HUD {
    enum State: Equatable {
        case hidden
        case listening
        /// Shows how to finish ("tap ⌥").
        case handsFree(String)
        case transcribing
        case message(String)
    }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let meter = LevelMeter()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        panel.contentView = bg

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.frame = NSRect(x: 14, y: 13, width: 10, height: 10)
        bg.addSubview(dot)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 32, y: 9, width: 130, height: 18)
        bg.addSubview(label)

        meter.frame = NSRect(x: 168, y: 9, width: 40, height: 18)
        bg.addSubview(meter)
    }

    func set(_ state: State) {
        hideWork?.cancel()
        switch state {
        case .hidden:
            panel.orderOut(nil)
            return
        case .listening:
            show("Listening", color: .systemRed, meter: true)
        case .handsFree(let finish):
            show("Hands-free · \(finish)", color: .systemOrange, meter: true)
        case .transcribing:
            show("Writing…", color: .systemBlue, meter: false)
        case .message(let text):
            show(text, color: .systemGray, meter: false)
            let w = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
        }
    }

    func level(_ db: Double) { meter.level = max(0, min(1, (db + 60) / 45)) }

    private func show(_ text: String, color: NSColor, meter showMeter: Bool) {
        label.stringValue = text
        dot.layer?.backgroundColor = color.cgColor
        meter.isHidden = !showMeter
        meter.level = 0
        let width: CGFloat = showMeter ? 220 : max(140, label.intrinsicContentSize.width + 50)
        label.frame.size.width = showMeter ? 130 : width - 44
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.minY + 24, width: width, height: 36), display: true)
        }
        panel.orderFrontRegardless()
    }
}

final class LevelMeter: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    private var history = [Double](repeating: 0, count: 6)

    override func draw(_ dirtyRect: NSRect) {
        history.removeFirst()
        history.append(level)
        let w: CGFloat = 4, gap: CGFloat = 3
        NSColor.labelColor.withAlphaComponent(0.8).setFill()
        for (i, v) in history.enumerated() {
            let h = max(3, bounds.height * CGFloat(v))
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
    }
}
