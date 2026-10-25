#if NATIVESHOT_QA
import AppKit
import AVFoundation
import CoreImage

/// Second process that shows deterministic content for the self-test (QARunner). Prints one JSON line
/// with its window geometry (Quartz global points) on stdout, then stays up until terminated.
@MainActor
enum QAFixture {
    static let contentSize = NSSize(width: 640, height: 400)
    static let qrPayload = "https://example.com/nativeshot-qa"
    private static var window: NSWindow?
    private static var tone: AVAudioEngine?

    static func run(mode: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screen = NSScreen.screens[0]
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.minX + 80, y: vf.maxY - 80 - contentSize.height)
        let w = NSWindow(contentRect: NSRect(origin: origin, size: contentSize), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "NS-QA-Fixture"
        w.level = .floating // stay visible even if the user is working in another app
        w.isReleasedWhenClosed = false
        switch mode {
        case "scroll": w.contentView = makeScrollView()
        case "audio": w.contentView = AnimatedView(frame: NSRect(origin: .zero, size: contentSize)); startTone()
        case "animated": w.contentView = AnimatedView(frame: NSRect(origin: .zero, size: contentSize))
        case "paste":
            // ⌘V reaches a text view through the Edit menu, like in any real app.
            let main = NSMenu(), edit = NSMenuItem()
            edit.submenu = NSMenu(title: "Edit")
            edit.submenu!.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            main.addItem(edit)
            app.mainMenu = main
            w.contentView = makePasteTarget()
        default: w.contentView = StaticView(frame: NSRect(origin: .zero, size: contentSize))
        }
        w.orderFrontRegardless()
        window = w
        // Report geometry once the window server has placed it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let content = w.convertToScreen(w.contentLayoutRect)
            let q = CGRect(x: content.minX, y: screen.frame.height - content.maxY, width: content.width, height: content.height)
            let outer = CGRect(x: w.frame.minX, y: screen.frame.height - w.frame.maxY, width: w.frame.width, height: w.frame.height)
            let info: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": w.windowNumber,
                                       "content": [q.minX, q.minY, q.width, q.height],
                                       "frame": [outer.minX, outer.minY, outer.width, outer.height],
                                       "scale": screen.backingScaleFactor]
            let data = try! JSONSerialization.data(withJSONObject: info)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        app.run()
    }

    // MARK: Paste: rich text view like TextEdit/Mail/Notes; reports every change on stdout.

    private static var pasteDelegate: PasteDelegate?

    static func makePasteTarget() -> NSView {
        let sv = NSTextView.scrollableTextView()
        sv.frame = NSRect(origin: .zero, size: contentSize)
        let tv = sv.documentView as! NSTextView
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsImageEditing = true
        let d = PasteDelegate()
        tv.delegate = d
        pasteDelegate = d
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(tv)
        }
        return sv
    }

    final class PasteDelegate: NSObject, NSTextViewDelegate {
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView, let ts = tv.textStorage else { return }
            var sizes: [[Double]] = []
            ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length)) { v, _, _ in
                guard let a = v as? NSTextAttachment else { return }
                let img = a.image ?? a.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
                if let rep = img?.representations.first { sizes.append([Double(rep.pixelsWide), Double(rep.pixelsHigh)]) }
                else { sizes.append([0, 0]) }
            }
            let data = try! JSONSerialization.data(withJSONObject: ["attachments": sizes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }

    // MARK: Static: four pure-colour quadrants on top, text + QR below.

    final class StaticView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let half = bounds.width / 2
            let colors: [NSColor] = [.init(srgbRed: 1, green: 0, blue: 0, alpha: 1), .init(srgbRed: 0, green: 0.8, blue: 0, alpha: 1),
                                     .init(srgbRed: 0, green: 0, blue: 1, alpha: 1), .init(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)]
            for (i, c) in colors.enumerated() {
                c.setFill()
                NSRect(x: CGFloat(i % 2) * half, y: CGFloat(i / 2) * 100, width: half, height: 100).fill()
            }
            NSColor.white.setFill()
            NSRect(x: 0, y: 200, width: bounds.width, height: 200).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black]
            ("NativeShot QA 2026" as NSString).draw(at: NSPoint(x: 20, y: 225), withAttributes: attrs)
            ("Número de pedido 4815" as NSString).draw(at: NSPoint(x: 20, y: 270), withAttributes: attrs)
            ("Canción año acción" as NSString).draw(at: NSPoint(x: 20, y: 315), withAttributes: attrs)
            if let qr = QAFixture.qrImage() {
                NSImage(cgImage: qr, size: NSSize(width: 150, height: 150)).draw(in: NSRect(x: 470, y: 225, width: 150, height: 150))
            }
        }
    }

    static func qrImage() -> CGImage? {
        let f = CIFilter(name: "CIQRCodeGenerator")!
        f.setValue(Data(qrPayload.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }

    // MARK: Scroll: tall document with numbered, uniquely patterned rows.

    static let scrollRows = 120
    static let rowHeight: CGFloat = 44

    static func makeScrollView() -> NSScrollView {
        let sv = NSScrollView(frame: NSRect(origin: .zero, size: contentSize))
        sv.hasVerticalScroller = false
        sv.drawsBackground = true
        sv.backgroundColor = .white
        let doc = TallView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: CGFloat(scrollRows) * rowHeight))
        sv.documentView = doc
        doc.scroll(.zero)
        return sv
    }

    final class TallView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); dirtyRect.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.black]
            let first = max(0, Int(dirtyRect.minY / QAFixture.rowHeight)), last = min(QAFixture.scrollRows - 1, Int(dirtyRect.maxY / QAFixture.rowHeight))
            guard first <= last else { return }
            for r in first...last {
                let y = CGFloat(r) * QAFixture.rowHeight
                // Unique per-row bar widths make every row distinguishable for the aligner.
                var seed = UInt32(r &* 2654435761 & 0xffff_ffff)
                for b in 0..<6 {
                    seed = seed &* 1103515245 &+ 12345
                    let w = CGFloat(20 + Int(seed >> 16) % 90)
                    NSColor(hue: CGFloat((r * 37 + b * 11) % 100) / 100, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
                    NSRect(x: 260 + CGFloat(b) * 60, y: y + 10, width: min(w, 56), height: 24).fill()
                }
                (String(format: "FILA %04d", r + 1) as NSString).draw(at: NSPoint(x: 20, y: y + 10), withAttributes: attrs)
                NSColor(white: 0.85, alpha: 1).setFill()
                NSRect(x: 0, y: y + QAFixture.rowHeight - 1, width: bounds.width, height: 1).fill()
            }
        }
    }

    // MARK: Audio/video: moving square + 880 Hz tone through the default output.

    final class AnimatedView: NSView {
        private var t = 0
        private var link: CADisplayLink?
        override init(frame: NSRect) {
            super.init(frame: frame)
        }
        // Display-rate animation (not a 30 Hz Timer, which drifts): every captured frame has new content.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, link == nil else { return }
            let l = displayLink(target: self, selector: #selector(tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc private func tick() { t += 1; needsDisplay = true }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.15, alpha: 1).setFill(); bounds.fill()
            NSColor.systemOrange.setFill()
            let x = CGFloat((t * 4) % Int(bounds.width - 80))
            NSRect(x: x, y: bounds.midY - 40, width: 80, height: 80).fill()
        }
    }

    /// Nonisolated: the render block runs on the real-time audio thread, a MainActor closure would trap there.
    nonisolated static func toneRenderer(sampleRate sr: Double) -> AVAudioSourceNodeRenderBlock {
        nonisolated(unsafe) var phase = 0.0
        return { _, _, frames, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for f in 0..<Int(frames) {
                let v = Float(sin(phase) * 0.08)
                phase += 2 * .pi * 880 / sr
                for b in buffers { b.mData!.assumingMemoryBound(to: Float.self)[f] = v }
            }
            return noErr
        }
    }

    static func startTone() {
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sr = format.sampleRate
        let node = AVAudioSourceNode(renderBlock: toneRenderer(sampleRate: sr))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sr, channels: format.channelCount))
        try? engine.start()
        tone = engine
    }
}
#endif
