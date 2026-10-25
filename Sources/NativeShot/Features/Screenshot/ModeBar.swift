import AppKit
import SwiftUI
import NativeShotKit

/// Floating mode bar of the all-in-one selector (CAP-004, UI-03).
final class ModeBarPanel: NSPanel {
    private let model: ModeBarModel
    private weak var overlay: SelectionOverlay?

    @MainActor
    init(overlay: SelectionOverlay) {
        model = ModeBarModel(mode: overlay.mode)
        self.overlay = overlay
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true // only the size fields need keyboard focus
        let host = NSHostingView.fixed(ModeBar(model: model, screenshot: overlay.screenshot,
                                                   optionsChanged: { [weak overlay] in overlay?.optionsChanged() },
                                                   applySize: { [weak overlay] in overlay?.applySize($0, pixels: $1) },
                                                   select: { [weak overlay] in overlay?.setMode($0) },
                                                   switchTo: { [weak overlay] in overlay?.switchTo($0) },
                                                   cancel: { [weak overlay] in overlay?.finish(nil) }))
        contentView = host
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { overlay?.finish(nil) } }

    @MainActor
    func show(on screen: NSScreen) {
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 24))
        orderFrontRegardless()
    }

    @MainActor
    func update(mode: SelectionOverlay.Mode) { model.mode = mode }

    @MainActor
    func update(selection: CGSize?, scale: CGFloat) { model.selection = selection; model.scale = scale }
}

@MainActor
final class ModeBarModel: ObservableObject {
    @Published var mode: SelectionOverlay.Mode
    /// Size in points of the region being edited, and the backing scale of its display.
    @Published var selection: CGSize?
    @Published var scale: CGFloat = 1
    init(mode: SelectionOverlay.Mode) { self.mode = mode }
}

struct ModeBar: View {
    @ObservedObject var model: ModeBarModel
    let screenshot: Bool
    let optionsChanged: () -> Void
    let applySize: (CGSize, Bool) -> Void
    let select: (SelectionOverlay.Mode) -> Void
    let switchTo: (ShortcutAction) -> Void
    let cancel: () -> Void

    @AppStorage(Prefs.timerSeconds) private var timer = 0
    @AppStorage(Prefs.aspectPreset) private var aspect = AspectPreset.free.rawValue
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var width = ""
    @State private var height = ""
    @State private var pixels = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 6) {
            modes
            sizeRow
        }
        .padding(8)
        .panelBackground(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(1)
    }

    private var modes: some View {
        HStack(spacing: 4) {
            button(.region, "Región", "rectangle.dashed")
            button(.window, "Ventana", "macwindow")
            button(.display, "Pantalla", "display")
            Divider().frame(height: 22).padding(.horizontal, 4)
            action(.scrolling, "Scroll", "arrow.up.and.down.text.horizontal")
            action(.textRecognition, "Texto", "text.viewfinder")
            action(.recordScreen, "Grabar", "record.circle")
            Divider().frame(height: 22).padding(.horizontal, 4)
            Menu {
                Picker("Temporizador", selection: $timer) {
                    Text("Sin temporizador").tag(0); Text("3 s").tag(3); Text("5 s").tag(5); Text("10 s").tag(10)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: timer == 0 ? "timer" : "timer.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Temporizador"))
            .accessibilityLabel(Text("Temporizador"))
            .accessibilityValue(timer == 0 ? Text("Sin temporizador") : Text("\(timer) s"))
            options
            Button(action: cancel) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(Text("Cancelar (Esc)"))
                .accessibilityLabel(Text("Cancelar"))
        }
    }

    /// CAP-006: fixed aspect and exact size of the region being edited.
    private var sizeRow: some View {
        let editable = model.mode == .region && model.selection != nil
        return HStack(spacing: 6) {
            Picker("Proporción", selection: $aspect) {
                Text("Libre").tag(AspectPreset.free.rawValue)
                Text("1:1").tag(AspectPreset.square.rawValue)
                Text("4:3").tag(AspectPreset.fourThree.rawValue)
                Text("3:2").tag(AspectPreset.threeTwo.rawValue)
                Text("16:9").tag(AspectPreset.sixteenNine.rawValue)
            }
            .labelsHidden().fixedSize()
            .help(Text("Proporción fija al arrastrar (Mayúsculas = cuadrado)"))
            .accessibilityLabel(Text("Proporción"))
            Divider().frame(height: 18)
            TextField("Ancho", text: $width).frame(width: 56).focused($typing).onSubmit(commit)
                .accessibilityLabel(Text("Ancho"))
            Text("×").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Alto", text: $height).frame(width: 56).focused($typing).onSubmit(commit)
                .accessibilityLabel(Text("Alto"))
            Picker("Unidad", selection: $pixels) {
                Text("pt").tag(false)
                Text("px").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityLabel(Text("Unidad de medida"))
        }
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.center)
        .disabled(!editable)
        .onChange(of: model.selection) { syncFields() }
        .onChange(of: pixels) { syncFields() }
    }

    private func syncFields() {
        guard !typing else { return }
        guard let s = model.selection else { width = ""; height = ""; return }
        let k = pixels ? model.scale : 1
        width = String(Int((s.width * k).rounded()))
        height = String(Int((s.height * k).rounded()))
    }

    private func commit() {
        typing = false
        if let w = Double(width), let h = Double(height) { applySize(CGSize(width: w, height: h), pixels) }
        syncFields()
    }

    /// Persistent switches (CAP-001/009/010/011/012/019); each writes its preference and tells the overlay.
    private var options: some View {
        func toggle(_ title: LocalizedStringKey, _ key: String) -> some View {
            Toggle(title, isOn: Binding(get: { UserDefaults.standard.bool(forKey: key) },
                                        set: { UserDefaults.standard.set($0, forKey: key); optionsChanged() }))
        }
        return Menu {
            toggle("Ajustar la región tras soltar", Prefs.adjustRegion)
            if screenshot {
                toggle("Congelar pantalla", Prefs.freezeScreen)
                toggle("Lupa con color bajo el puntero", Prefs.showLoupe)
                toggle("Varias regiones (⌘): unir en una imagen", Prefs.multiRegionJoin)
                toggle("Ocultar iconos del escritorio", Prefs.hideDesktopIcons)
            }
            if NSScreen.screens.contains(where: { $0.safeAreaInsets.top > 0 }) {
                toggle("Excluir el notch en pantalla completa", Prefs.excludeNotch)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Opciones de captura"))
        .accessibilityLabel(Text("Opciones de captura"))
    }

    private func button(_ m: SelectionOverlay.Mode, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Button { select(m) } label: {
            Label(title, systemImage: symbol)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(model.mode == m ? Color.accentColor.opacity(contrast == .increased ? 0.6 : 0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(model.mode == m ? .isSelected : [])
    }

    /// Not a mode: leaves the selector and starts that flow through the same entry point as its shortcut.
    private func action(_ a: ShortcutAction, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Button { switchTo(a) } label: {
            Label(title, systemImage: symbol).padding(.horizontal, 8).padding(.vertical, 4)
        }
        .buttonStyle(.borderless)
    }
}
