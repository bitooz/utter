import AppKit
import AVFoundation

/// `Utter --capture-hud DIR`: plays the real pill through every state, off screen, stepped at exactly 60 frames a second
/// (a made-up voice drives the waveform), and records each frame over a light and a dark backdrop, the way the pill's
/// own layers draw it (no screen capture). Writes hud-light.mp4 and hud-dark.mp4, a still of each state, filmstrips of
/// the changes, and hud-frames.txt: what each frame cost to work out, and how far any size went past where it was going.
@MainActor
enum HUDCapture {
    static let fps = 60.0
    static let canvas = CGSize(width: 300, height: 110) // points, recorded at 2×
    static let scale: CGFloat = 2

    struct Beat {
        var state: HUD.State
        var seconds: Double
        var talking = false
        var stills: [(name: String, at: Double)] = []
        /// Records the first half second after the change as a filmstrip.
        var strip: String?
    }

    static let beats: [Beat] = [
        Beat(state: .hidden, seconds: 0.3),
        Beat(state: .listening, seconds: 2.6, talking: true, stills: [("listening", 0.62), ("listening-pause", 1.62)], strip: "appear"),
        Beat(state: .transcribing, seconds: 1.8, stills: [("writing", 1.2)], strip: "listening-to-writing"),
        Beat(state: .hidden, seconds: 0.7, strip: "writing-to-gone"),
        Beat(state: .handsFree, seconds: 2.0, talking: true, stills: [("hands-free", 0.62)]),
        Beat(state: .transcribing, seconds: 1.0),
        Beat(state: .notice(.copied), seconds: 1.5, stills: [("copied", 0.9)], strip: "writing-to-copied"),
        Beat(state: .hidden, seconds: 0.6),
        Beat(state: .listening, seconds: 0.8, talking: true),
        Beat(state: .transcribing, seconds: 0.8),
        Beat(state: .notice(.failed), seconds: 1.5, stills: [("failed", 0.9)]),
        Beat(state: .notice(.partMissing), seconds: 1.2, stills: [("part-missing", 0.9)]),
        Beat(state: .notice(.notPasted), seconds: 1.2, stills: [("not-pasted", 0.9)]),
        Beat(state: .notice(.noSpeech), seconds: 1.2, stills: [("no-speech", 0.9)]),
        Beat(state: .notice(.cancelled), seconds: 1.2, stills: [("cancelled", 0.9)]),
        Beat(state: .notice(.needsKey), seconds: 1.2, stills: [("needs-key", 0.9)]),
        Beat(state: .notice(.micUnavailable), seconds: 1.2, stills: [("mic-unavailable", 0.9)]),
        Beat(state: .hidden, seconds: 0.8),
    ]

    /// Talking in two runs of syllables with a pause between, over a quiet room (dBFS).
    static func voice(_ t: Double) -> Double {
        let talking = (0.15...1.35).contains(t) || (1.65...2.45).contains(t)
        guard talking else { return -58 + 2 * sin(t * 31) }
        let syllable = pow(abs(sin(.pi * 4.3 * t)), 0.7) * (0.55 + 0.45 * abs(sin((t * 4.3).rounded(.down) * 2.3)))
        let phrase = 0.75 + 0.25 * sin(2 * .pi * 0.8 * t)
        return -58 + 32 * syllable * phrase
    }

    static func run(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var report: [String] = []
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            report += record(dark: dark, dir: dir)
        }
        NSApp.appearance = nil
        try? (report.joined(separator: "\n") + "\n").write(toFile: "\(dir)/hud-frames.txt", atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
    }

    private static func record(dark: Bool, dir: String) -> [String] {
        let look = dark ? "dark" : "light"
        let hud = HUD(onScreen: false)
        let px = (w: Int(canvas.width * scale), h: Int(canvas.height * scale))
        let url = URL(fileURLWithPath: "\(dir)/hud-\(look).mp4")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return ["\(look): can't write the video"] }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: px.w, AVVideoHeightKey: px.h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: px.w, kCVPixelBufferHeightKey as String: px.h])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var frame = 0
        var costs: [Double] = []
        var biggestPass = (share: 0.0, at: "")
        var biggestStep: CGFloat = 0
        for beat in beats {
            hud.set(beat.state)
            let from = hud.pillSize.width, to = hud.pillTargetWidth
            var strip: [CGImage] = []
            var last = hud.pillSize.width
            for k in 0..<Int((beat.seconds * fps).rounded()) {
                let t = Double(k) / fps
                if beat.talking { hud.level(voice(t)) } else { hud.level(-60) }
                let start = DispatchTime.now().uptimeNanoseconds
                hud.advance(1 / fps)
                costs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)

                // How far the width went past its target, as a share of the way it had to go.
                let w = hud.pillSize.width
                if abs(to - from) > 1 {
                    let past = Double((w - to) * (to > from ? 1 : -1) / abs(to - from))
                    if past > biggestPass.share { biggestPass = (past, "\(beat.state)") }
                }
                biggestStep = max(biggestStep, abs(w - last))
                last = w

                guard let image = draw(hud, dark: dark, size: px) else { continue }
                append(image, frame, adaptor, input)
                frame += 1
                for s in beat.stills where k == Int((s.at * fps).rounded()) {
                    savePNG(image, to: "\(dir)/hud-\(s.name)-\(look).png")
                }
                if beat.strip != nil, k <= 30, k % 3 == 0 { strip.append(image) }
            }
            if let name = beat.strip { savePNG(filmstrip(strip, dark: dark), to: "\(dir)/hud-strip-\(name)-\(look).png") }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        let sorted = costs.sorted()
        return [
            "\(look): \(frame) frames at \(Int(fps)) fps (\(String(format: "%.1f", Double(frame) / fps)) s), \(writer.status == .completed ? "hud-\(look).mp4 written" : "video FAILED: \(writer.error.map { "\($0)" } ?? "?")")",
            String(format: "  work per frame (springs, bars, layout): median %.0f µs, 99th percentile %.0f µs, most %.0f µs (a frame at 60 fps has 16 667 µs)",
                   sorted[sorted.count / 2], sorted[sorted.count * 99 / 100], sorted.last ?? 0),
            String(format: "  most the pill's width went past its target: %.1f%% of the change (%@)", biggestPass.share * 100, biggestPass.at),
            String(format: "  biggest change in width from one frame to the next: %.1f pt", biggestStep),
        ]
    }

    /// One frame: the backdrop, then the pill's layers as they are now.
    private static func draw(_ hud: HUD, dark: Bool, size: (w: Int, h: Int)) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size.w, height: size.h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let top = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1) : CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        let bottom = dark ? CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1) : CGColor(srgbRed: 0.89, green: 0.89, blue: 0.91, alpha: 1)
        let gradient = CGGradient(colorsSpace: nil, colors: [bottom, top] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: canvas.height), options: [])
        ctx.translateBy(x: (canvas.width - HUD.canvas.width) / 2, y: (canvas.height - HUD.canvas.height) / 2)
        hud.root.render(in: ctx)
        return ctx.makeImage()
    }

    private static func append(_ image: CGImage, _ frame: Int, _ adaptor: AVAssetWriterInputPixelBufferAdaptor, _ input: AVAssetWriterInput) {
        while !input.isReadyForMoreMediaData { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        guard let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }

    /// Every third frame of the first half second after a change (50 ms apart), cut to the pill, in rows of four.
    private static func filmstrip(_ frames: [CGImage], dark: Bool) -> CGImage {
        let crop = CGRect(x: (canvas.width - 150) / 2 * scale, y: (canvas.height - 60) / 2 * scale, width: 150 * scale, height: 60 * scale)
        let columns = 4, label: CGFloat = 16 * scale
        let cellW = crop.width, cellH = crop.height + label
        let rows = (frames.count + columns - 1) / columns
        let ctx = CGContext(data: nil, width: Int(cellW) * columns, height: Int(cellH) * rows, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1) : CGColor(srgbRed: 0.89, green: 0.89, blue: 0.91, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, f) in frames.enumerated() {
            let x = CGFloat(i % columns) * cellW, y = CGFloat(rows - 1 - i / columns) * cellH
            // CGImage rows run top down; the crop's y counts from the bottom.
            if let piece = f.cropping(to: CGRect(x: crop.minX, y: CGFloat(f.height) - crop.maxY, width: crop.width, height: crop.height)) {
                ctx.draw(piece, in: CGRect(x: x, y: y, width: crop.width, height: crop.height))
            }
            let text = "\(i * 50) ms" as NSString
            text.draw(at: NSPoint(x: x + 8 * scale, y: y + crop.height + 2 * scale), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10 * scale, weight: .medium),
                .foregroundColor: dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.5)])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private static func savePNG(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
