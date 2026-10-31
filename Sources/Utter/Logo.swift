import AppKit
import SwiftUI

/// Utter's mark, drawn in code so the app icon, the menu bar icon and the setup window all match.
/// Three designs; `current` is the one the app uses (the others are saved as alternatives by `--make-icons`).
enum Logo {
    enum Style: String, CaseIterable {
        /// A text cursor sending out sound waves (speech becomes typing), white on a graphite tile.
        case cursor
        /// A voice's waveform.
        case wave
        /// A speech bubble with a waveform cut out of it.
        case bubble
    }

    static let current = Style.cursor

    enum State { case idle, recording, problem }

    // MARK: App icon

    /// The app icon on the macOS grid: an 824-pt squircle on a 1024-pt canvas, with a soft shadow.
    /// `framed: false` draws the tile alone, edge to edge, with no margin and no shadows: for the logo inside Utter's own
    /// windows, where the icon grid's drop shadow would show as a box around a small icon.
    static func appIcon(_ style: Style = current, size: CGFloat = 1024, framed: Bool = true) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / (framed ? 1024 : 824)
            cg.scaleBy(x: s, y: s)
            if !framed { cg.translateBy(x: -100, y: -100) }
            let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
            let shape = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tile).cgPath

            if framed {
            cg.saveGState()
            // Shadows ignore the scale above, so size them for the actual pixels.
            cg.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
            cg.addPath(shape)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
            cg.restoreGState()
            }

            cg.saveGState()
            cg.addPath(shape)
            cg.clip()
            let (top, bottom) = colors(style)
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // A soft light from the top, like a glass tile.
            let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [NSColor.white.withAlphaComponent(style == .cursor ? 0.08 : 0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                   locations: [0, 1])!
            cg.drawRadialGradient(shine, startCenter: CGPoint(x: 512, y: 980), startRadius: 0, endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
            cg.restoreGState()

            // Thin inner edge (in windows, the view draws its own hairline instead).
            if framed {
            cg.addPath(RoundedRectangle(cornerRadius: 183, style: .continuous).path(in: tile.insetBy(dx: 2, dy: 2)).cgPath)
            cg.setStrokeColor(NSColor.white.withAlphaComponent(style == .cursor ? 0.14 : 0.18).cgColor)
            cg.setLineWidth(4)
            cg.strokePath()
            }

            cg.saveGState()
            if framed {
                cg.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            }
            drawGlyph(style, in: cg, box: CGRect(x: 512 - 260, y: 512 - 260, width: 520, height: 520), color: .white, icon: true, bottom: bottom)
            cg.restoreGState()
            return true
        }
    }

    private static func colors(_ style: Style) -> (NSColor, NSColor) {
        switch style {
        // Graphite, near black: a calm tile that lets the white glyph carry the mark.
        case .cursor: return (NSColor(srgbRed: 0.235, green: 0.235, blue: 0.255, alpha: 1), NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 1))
        case .wave: return (NSColor(srgbRed: 0.40, green: 0.43, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.62, green: 0.26, blue: 0.93, alpha: 1))
        case .bubble: return (NSColor(srgbRed: 0.10, green: 0.80, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 1))
        }
    }

    // MARK: Menu bar

    /// The menu bar icon: an 18-pt glyph like the system's own. Idle and problem are template images
    /// (the menu bar tints them); recording is drawn in red.
    static func menuBarIcon(_ state: State, style: Style = current) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 18
            cg.scaleBy(x: s, y: s)
            let color: NSColor = state == .recording ? .systemRed : .black
            drawGlyph(style, in: cg, box: CGRect(x: 1, y: 1, width: 16, height: 16), color: color, icon: false, bottom: nil)
            if state == .problem {
                // A slash through it, with a gap cut on either side so it reads at this size.
                cg.setBlendMode(.clear)
                cg.setLineWidth(3.6)
                cg.setLineCap(.round)
                cg.move(to: CGPoint(x: 2.5, y: 15.5)); cg.addLine(to: CGPoint(x: 15.5, y: 2.5))
                cg.strokePath()
                cg.setBlendMode(.normal)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(1.5)
                cg.move(to: CGPoint(x: 2.5, y: 15.5)); cg.addLine(to: CGPoint(x: 15.5, y: 2.5))
                cg.strokePath()
            }
            return true
        }
        img.isTemplate = state != .recording
        img.accessibilityDescription = "Utter"
        return img
    }

    // MARK: Glyphs

    /// Draws a style's glyph filling `box` (square). `icon`: the large version on the app tile (finer detail);
    /// `bottom`: the tile's lower color, for cut-outs.
    private static func drawGlyph(_ style: Style, in cg: CGContext, box b: CGRect, color: NSColor, icon: Bool, bottom: NSColor?) {
        let u = b.width / 100 // glyph units: the box is 100 × 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: b.minX + x * u, y: b.minY + y * u) }
        cg.setFillColor(color.cgColor)
        cg.setStrokeColor(color.cgColor)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        switch style {
        case .cursor:
            // I-beam: stem and two serifs.
            let stem: CGFloat = icon ? 9 : 11
            cg.setLineWidth(stem * u)
            cg.move(to: p(50, 17)); cg.addLine(to: p(50, 83)); cg.strokePath()
            let serif: CGFloat = icon ? 11 : 9
            cg.move(to: p(50 - serif, 83)); cg.addLine(to: p(50 + serif, 83)); cg.strokePath()
            cg.move(to: p(50 - serif, 17)); cg.addLine(to: p(50 + serif, 17)); cg.strokePath()
            // Sound waves on both sides.
            let waves: [(CGFloat, CGFloat)] = icon ? [(27, 1), (43, 0.55)] : [(29, 1), (45, 1)]
            for (r, alpha) in waves {
                cg.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
                cg.setLineWidth((icon ? 8 : 9) * u)
                for side in [CGFloat.pi, 0] {
                    let span = CGFloat.pi / 4.2
                    cg.addArc(center: p(50, 50), radius: r * u, startAngle: side - span, endAngle: side + span, clockwise: false)
                    cg.strokePath()
                }
            }

        case .wave:
            // A spoken phrase: bars of a voice, loudest in the middle.
            let heights: [CGFloat] = icon ? [26, 52, 80, 60, 88, 44, 24] : [34, 66, 96, 58, 30]
            let w: CGFloat = icon ? 9 : 13, gap: CGFloat = icon ? 5.5 : 7
            let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
            var x = 50 - total / 2
            for h in heights {
                let r = CGRect(x: b.minX + x * u, y: b.minY + (50 - h / 2) * u, width: w * u, height: h * u)
                cg.addPath(CGPath(roundedRect: r, cornerWidth: w * u / 2, cornerHeight: w * u / 2, transform: nil))
                cg.fillPath()
                x += w + gap
            }

        case .bubble:
            // Speech bubble with a tail at the lower left.
            let body = CGRect(x: b.minX + 6 * u, y: b.minY + 22 * u, width: 88 * u, height: 66 * u)
            let path = CGMutablePath()
            path.addPath(RoundedRectangle(cornerRadius: 22 * u, style: .continuous).path(in: body).cgPath)
            path.move(to: p(22, 26)); path.addLine(to: p(14, 8)); path.addLine(to: p(40, 24)); path.closeSubpath()
            if icon {
                cg.addPath(path); cg.fillPath()
            } else {
                cg.addPath(path); cg.fillPath()
            }
            // Waveform cut out of the bubble.
            let heights: [CGFloat] = [16, 34, 24, 40, 18]
            let w: CGFloat = icon ? 7 : 8, gap: CGFloat = icon ? 6 : 4.5
            let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
            var x = 50 - total / 2
            if let bottom, icon { cg.setFillColor(bottom.cgColor) } else { cg.setBlendMode(.clear) }
            for h in heights {
                let r = CGRect(x: b.minX + x * u, y: b.minY + (55 - h / 2) * u, width: w * u, height: h * u)
                cg.addPath(CGPath(roundedRect: r, cornerWidth: w * u / 2, cornerHeight: w * u / 2, transform: nil))
                cg.fillPath()
                x += w + gap
            }
            cg.setBlendMode(.normal)
        }
    }

    // MARK: Files

    /// `Utter --make-icons DIR`: each design as a 1024 PNG and a menu bar preview, plus `AppIcon.iconset` for the current one.
    static func writeFiles(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for style in Style.allCases {
            png(appIcon(style, size: 1024), px: 1024, to: "\(dir)/icon-\(style.rawValue).png")
            png(menuBarPreview(style), px: nil, to: "\(dir)/menubar-\(style.rawValue).png")
        }
        png(onBackground(current, light: true), px: nil, to: "\(dir)/icon-\(current.rawValue)-on-light.png")
        png(onBackground(current, light: false), px: nil, to: "\(dir)/icon-\(current.rawValue)-on-dark.png")
        let set = "\(dir)/AppIcon.iconset"
        try? fm.createDirectory(atPath: set, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            png(appIcon(current, size: CGFloat(pt)), px: pt, to: "\(set)/icon_\(pt)x\(pt).png")
            png(appIcon(current, size: CGFloat(pt)), px: pt * 2, to: "\(set)/icon_\(pt)x\(pt)@2x.png")
        }
        print("wrote icons to \(dir)")
    }

    /// The icon at Dock sizes (128, 64, 32 pt) on a light or dark desktop, to judge the tile against its surroundings.
    private static func onBackground(_ style: Style, light: Bool) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 160), flipped: false) { rect in
            (light ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
            rect.fill()
            var x: CGFloat = 16
            for size in [CGFloat(128), 64, 32] {
                appIcon(style, size: size).draw(in: NSRect(x: x, y: (rect.height - size) / 2, width: size, height: size))
                x += size + 18
            }
            return true
        }
    }

    /// The glyph in its three states on a light and a dark menu bar strip, at 2× (how it looks next to its neighbours).
    private static func menuBarPreview(_ style: Style) -> NSImage {
        NSImage(size: NSSize(width: 228, height: 64), flipped: false) { rect in
            for (row, dark) in [(1, false), (0, true)] {
                let y = CGFloat(row) * 32
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: rect.width, height: 32).fill()
                let ink: NSColor = dark ? .white : .black
                var x: CGFloat = 12
                for state in [State.idle, .recording, .problem] {
                    let g = menuBarIcon(state, style: style)
                    let tinted = NSImage(size: g.size, flipped: false) { r in
                        g.draw(in: r)
                        if g.isTemplate { ink.set(); r.fill(using: .sourceAtop) }
                        return true
                    }
                    tinted.draw(in: NSRect(x: x, y: y + 7, width: 18, height: 18))
                    x += 30
                }
                // Neighbours for scale: system symbols at menu bar size.
                for name in ["wifi", "battery.75percent", "magnifyingglass"] {
                    if let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
                        let r = NSRect(x: x, y: y + (32 - s.size.height) / 2, width: s.size.width, height: s.size.height)
                        let t = NSImage(size: s.size, flipped: false) { rr in s.draw(in: rr); ink.set(); rr.fill(using: .sourceAtop); return true }
                        t.draw(in: r)
                        x += s.size.width + 14
                    }
                }
            }
            return true
        }
    }

    private static func png(_ img: NSImage, px: Int?, to path: String) {
        let w = px ?? Int(img.size.width * 2), h = px ?? Int(img.size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
