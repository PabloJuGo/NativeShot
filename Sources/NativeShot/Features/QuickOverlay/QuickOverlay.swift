import AppKit
import SwiftUI

/// A finished capture as the UI sees it: pixels plus the stored original on disk.
struct Capture: Identifiable {
    let id: UUID
    let image: CGImage
    let fileURL: URL
    var nsImage: NSImage { NSImage(cgImage: image, size: .zero) }
}

/// Floating thumbnails after a capture (QAO-001..005). Stacked, one panel per capture.
@MainActor
final class QuickOverlayController {
    private var panels: [UUID: NSPanel] = [:]
    private var order: [UUID] = []
    private var lastClosed: Capture?
    let actions: CaptureActions

    init(actions: CaptureActions) { self.actions = actions }

    #if NATIVESHOT_QA
    var qaCount: Int { panels.count }
    func qaCloseAll() { for id in order { close(id) } }
    #endif

    func show(_ capture: Capture) {
        let panel = ThumbnailPanel()
        let close: () -> Void = { [weak self] in self?.close(capture.id, capture: capture) }
        // Keyboard path for the focused thumbnail (⌘C, ⌘S, Esc, arrows between stacked thumbnails); the buttons stay the pointer path.
        panel.handleKey = { [actions, weak self] e in
            let cmd = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            switch (e.keyCode, e.charactersIgnoringModifiers) {
            case (53, _): close()
            case (_, "c") where cmd: actions.copy(capture); close()
            case (_, "s") where cmd: actions.save(capture); close()
            case (_, "e") where cmd: actions.export(capture)
            case (_, "p") where cmd: actions.printCapture(capture)
            case (_, "r") where cmd: actions.repeatCapture(); close()
            case (123, _), (126, _): self?.focusNeighbor(of: capture.id, by: -1) // ← ↑ older
            case (124, _), (125, _): self?.focusNeighbor(of: capture.id, by: 1) // → ↓ newer
            default: return false
            }
            return true
        }
        let view = ThumbnailView(capture: capture, actions: actions, close: close,
                                 anchor: { [weak panel] in panel?.contentView },
                                 duration: UserDefaults.standard.double(forKey: Prefs.overlayDuration))
        let host = NSHostingView.fixed(view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panels[capture.id] = panel
        order.append(capture.id)
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: String(localized: "Captura lista"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func close(_ id: UUID, capture: Capture? = nil) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if let capture { lastClosed = capture }
        panel.orderOut(nil)
        layout()
    }

    /// QAO-004: bring back the last dismissed thumbnail.
    func restoreLast() {
        guard let c = lastClosed, FileManager.default.fileExists(atPath: c.fileURL.path) else { return }
        lastClosed = nil
        show(c)
    }

    /// Keyboard access: takes key focus on the newest thumbnail so ⌘C/⌘S/Esc and Tab reach it.
    func focusLatest() {
        guard let id = order.last, let p = panels[id] else { return }
        p.makeKeyAndOrderFront(nil)
    }

    /// QAO-004: moves key focus along the stack; it stops at both ends instead of wrapping.
    func focusNeighbor(of id: UUID, by step: Int) {
        guard let i = order.firstIndex(of: id), order.indices.contains(i + step), let p = panels[order[i + step]] else { return }
        p.makeKeyAndOrderFront(nil)
        NSAccessibility.post(element: p, notification: .layoutChanged)
    }

    var canRestore: Bool { lastClosed != nil }

    private func layout() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let corner = OverlayCorner(rawValue: UserDefaults.standard.string(forKey: Prefs.overlayCorner) ?? "") ?? .bottomLeft
        let margin: CGFloat = 16
        var offset: CGFloat = margin
        for id in order.reversed() {
            guard let p = panels[id] else { continue }
            let w = p.frame.width, h = p.frame.height
            let x = (corner == .bottomLeft || corner == .topLeft) ? f.minX + margin : f.maxX - w - margin
            let y = (corner == .bottomLeft || corner == .bottomRight) ? f.minY + offset : f.maxY - h - offset
            p.setFrameOrigin(NSPoint(x: x, y: y))
            offset += h + 10
        }
    }
}

final class ThumbnailPanel: NSPanel {
    @MainActor
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }

    var handleKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool { handleKey?(event) == true || super.performKeyEquivalent(with: event) }
    override func keyDown(with event: NSEvent) { if handleKey?(event) != true { super.keyDown(with: event) } }
}

/// Everything a thumbnail, pin or menu can do with a capture.
@MainActor
protocol CaptureActions: AnyObject {
    func copy(_ c: Capture)
    func save(_ c: Capture)
    func pin(_ c: Capture)
    func edit(_ c: Capture)
    func reveal(_ c: Capture)
    func delete(_ c: Capture)
    func share(_ c: Capture, from anchor: NSView)
    func copyPath(_ c: Capture)
    func export(_ c: Capture)
    func printCapture(_ c: Capture)
    func recognizeText(_ c: Capture)
    /// QAO-002 "Repetir": takes the same capture again (same region, window or display).
    func repeatCapture()
    func canExcludeFromHistory(_ c: Capture) -> Bool
    func excludeFromHistory(_ c: Capture)
}

struct ThumbnailView: View {
    let capture: Capture
    let actions: CaptureActions
    let close: () -> Void
    let anchor: () -> NSView?
    let duration: Double
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var focused = false
    /// Stays open while the share sheet is up: the pointer leaves the panel to reach it.
    @State private var sharing = false
    @State private var dismissTask: Task<Void, Never>?
    @State private var openers: [OpenWith.App] = []

    private var thumbSize: CGSize {
        let w = CGFloat(capture.image.width), h = CGFloat(capture.image.height)
        let s = min(220 / w, 140 / h, 1)
        return CGSize(width: max(w * s, 140), height: max(h * s, 70))
    }

    var body: some View { content.modifier(rotorActions) }

    private var content: some View {
        ZStack {
            Image(nsImage: capture.nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: thumbSize.width, height: thumbSize.height)
                .background(Color.black.opacity(0.05))
                .onDrag { NSItemProvider(contentsOf: capture.fileURL) ?? NSItemProvider() }
                .accessibilityLabel(Text("Miniatura de la captura. Arrástrala a otra app."))
            if hovering || focused { controls }
        }
        .frame(width: thumbSize.width, height: thumbSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(contrast == .increased ? Color.primary : Color.white.opacity(0.25)))
        .padding(1)
        .onHover { h in
            hovering = h
            if h { dismissTask?.cancel() } else { scheduleDismiss() }
        }
        .onAppear(perform: scheduleDismiss)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).receive(on: RunLoop.main)) { n in
            if (n.object as? NSWindow) === anchor()?.window { focused = true; dismissTask?.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification).receive(on: RunLoop.main)) { n in
            if (n.object as? NSWindow) === anchor()?.window { focused = false; scheduleDismiss() }
        }
    }

    /// Hover-only buttons are invisible to VoiceOver, so every action is also exposed as a rotor action.
    private var rotorActions: RotorActions { RotorActions(capture: capture, actions: actions, close: close, share: share) }

    /// Export manager, print, open with, OCR, repeat and "keep out of history". Same actions as the keyboard shortcuts.
    private var moreMenu: some View {
        Menu {
            Button("Exportar…") { actions.export(capture) }
            Button("Imprimir…") { actions.printCapture(capture) }
            Menu("Abrir con") {
                ForEach(openers) { app in Button(app.name) { OpenWith.open(capture.fileURL, with: app) } }
            }
            Button("Reconocer texto") { actions.recognizeText(capture) }
            Button("Repetir captura") { actions.repeatCapture(); close() }
            if actions.canExcludeFromHistory(capture) {
                Button("Excluir del historial") { actions.excludeFromHistory(capture); close() }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Más acciones")
        .accessibilityLabel("Más acciones")
        .onAppear { openers = OpenWith.apps(for: capture.fileURL) }
    }

    @ViewBuilder private var controls: some View {
        Color.black.opacity(0.45)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                action("Copiar", "doc.on.doc") { actions.copy(capture); close() }
                action("Guardar", "square.and.arrow.down") { actions.save(capture); close() }
                action("Editar", "pencil.and.scribble") { actions.edit(capture); close() }
            }
            HStack(spacing: 8) {
                icon("Fijar", "pin") { actions.pin(capture); close() }
                icon("Compartir", "square.and.arrow.up", action: share)
                icon("Copiar ruta", "link") { actions.copyPath(capture) }
                icon("Mostrar en Finder", "folder") { actions.reveal(capture) }
                icon("Eliminar", "trash") { actions.delete(capture); close() }
                moreMenu
            }
        }
        VStack { HStack { Spacer(); icon("Cerrar", "xmark.circle.fill", action: close) }; Spacer() }.padding(4)
    }

    private func share() {
        guard let v = anchor() else { return }
        sharing = true
        dismissTask?.cancel()
        actions.share(capture, from: v)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard duration > 0, !sharing, !focused else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { close() }
        }
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: symbol).font(.callout.weight(.medium)) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
    }

    private func icon(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white) }
            .buttonStyle(.plain)
            .help(Text(title))
            .accessibilityLabel(Text(title))
    }
}

private struct RotorActions: ViewModifier {
    let capture: Capture
    let actions: CaptureActions
    let close: () -> Void
    let share: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copiar")) { actions.copy(capture); close() }
        .accessibilityAction(named: Text("Guardar")) { actions.save(capture); close() }
        .accessibilityAction(named: Text("Editar")) { actions.edit(capture); close() }
        .accessibilityAction(named: Text("Fijar")) { actions.pin(capture); close() }
        .accessibilityAction(named: Text("Compartir"), share)
        .accessibilityAction(named: Text("Copiar ruta")) { actions.copyPath(capture) }
        .accessibilityAction(named: Text("Mostrar en Finder")) { actions.reveal(capture) }
        .accessibilityAction(named: Text("Eliminar")) { actions.delete(capture); close() }
        .accessibilityAction(named: Text("Exportar…")) { actions.export(capture) }
        .accessibilityAction(named: Text("Imprimir…")) { actions.printCapture(capture) }
        .accessibilityAction(named: Text("Reconocer texto")) { actions.recognizeText(capture) }
        .accessibilityAction(named: Text("Repetir captura")) { actions.repeatCapture(); close() }
        .accessibilityAction(named: Text("Cerrar"), close)
    }
}
