import SwiftUI
import UniformTypeIdentifiers
import NativeShotKit

private extension EditorColor {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .red
        self.init(n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }
}

private enum Dialog: Identifiable {
    case resizeImage, resizeCanvas, stylePreset, backdropPreset
    var id: Self { self }
    var title: String {
        switch self {
        case .resizeImage: String(localized: "Redimensionar imagen")
        case .resizeCanvas: String(localized: "Tamaño del lienzo")
        case .stylePreset: String(localized: "Guardar estilo")
        case .backdropPreset: String(localized: "Guardar fondo")
        }
    }
    var message: String {
        switch self {
        case .resizeImage: String(localized: "Escala la imagen y todas las anotaciones. Si cambias solo un lado, el otro mantiene la proporción.")
        case .resizeCanvas: String(localized: "Cambia el tamaño del lienzo sin escalar: la imagen queda centrada y el espacio nuevo es transparente.")
        case .stylePreset, .backdropPreset: String(localized: "Ponle un nombre. Si ya existe, se reemplaza.")
        }
    }
}

/// Colour, stroke width and opacity for the selection (or for the next object), plus layers, image operations and background.
struct InspectorView: View {
    @ObservedObject var state: EditorState
    @State private var dialog: Dialog?
    @State private var field1 = ""
    @State private var field2 = ""
    @State private var sizeError = false

    private var style: AnnotationStyle { state.effectiveStyle }

    var body: some View {
        Form {
            styleSection
            imageSection
            Section("Recorte") {
                Button("Quitar recorte") { state.setCrop(nil) }
                    .disabled(state.document.crop == nil)
            }
            backgroundSection
        }
        .formStyle(.grouped)
        .frame(width: 250)
        .alert(dialog?.title ?? "", isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }), presenting: dialog) { d in
            switch d {
            case .resizeImage, .resizeCanvas:
                TextField("Ancho (px)", text: $field1)
                TextField("Alto (px)", text: $field2)
                Button("Aplicar") { applySize(d) }
            case .stylePreset, .backdropPreset:
                TextField("Nombre", text: $field1)
                Button("Guardar") { savePreset(d) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text($0.message) }
        .alert("Tamaño no válido", isPresented: $sizeError) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text("Usa un valor entre 1 y 32768 px, con menos de 100 millones de píxeles en total.") }
    }

    // MARK: Style / selection

    @ViewBuilder private var styleSection: some View {
        Section {
            ColorPicker("Color", selection: Binding(
                get: { style.color.swiftUI },
                set: { c in state.updateStyle { $0.color = EditorColor(c) } }), supportsOpacity: false)
            slider("Grosor", value: Binding(get: { style.width }, set: { v in state.updateStyle { $0.width = v } }), range: 1...40)
            slider("Opacidad", value: Binding(get: { style.opacity }, set: { v in state.updateStyle { $0.opacity = v } }), range: 0.1...1)
            if let sel = state.selected {
                objectParameters(sel)
                HStack {
                    Button { state.moveSelectedLayer(by: 1) } label: { Image(systemName: "square.2.layers.3d.top.filled") }
                        .help("Traer adelante").accessibilityLabel("Traer adelante")
                    Button { state.moveSelectedLayer(by: -1) } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }
                        .help("Enviar atrás").accessibilityLabel("Enviar atrás")
                    Button { state.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicar").accessibilityLabel("Duplicar objeto")
                    Button { state.toggleLock() } label: { Image(systemName: sel.locked ? "lock.fill" : "lock.open") }
                        .help(sel.locked ? "Desbloquear" : "Bloquear").accessibilityLabel(sel.locked ? "Desbloquear objeto" : "Bloquear objeto")
                    Button(role: .destructive) { state.deleteSelection() } label: { Image(systemName: "trash") }
                        .help("Eliminar").accessibilityLabel("Eliminar objeto")
                        .disabled(sel.locked)
                }
                alignMenu
            }
            presetsMenu
            Text("Pixelar, desenfocar y censurar reescriben los píxeles al exportar. El proyecto .nshot conserva el original.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            state.selected == nil ? Text("Estilo") : Text("Objeto seleccionado")
        }
    }

    @ViewBuilder private func objectParameters(_ sel: Annotation) -> some View {
        if sel.kind == .arrow {
            Toggle("Punta al inicio", isOn: object(\.headStart))
            Toggle("Punta al final", isOn: object(\.headEnd))
            slider("Curvatura", value: object(\.curve), range: -0.8...0.8)
        }
        if [.rectangle, .filledRectangle, .spotlight, .image].contains(sel.kind) {
            slider("Esquinas", value: object(\.cornerRadius), range: 0...100)
        }
        if sel.kind == .magnifier {
            slider("Aumento", value: object(\.magnification), range: 1.5...8)
        }
        if !sel.kind.isRedaction, sel.kind != .spotlight {
            Toggle("Sombra", isOn: object(\.shadow))
        }
    }

    private var alignMenu: some View {
        let many = state.allSelected.count
        return Menu("Alinear") {
            Button("A la izquierda") { state.align(.left) }
            Button("Centrar horizontalmente") { state.align(.centerX) }
            Button("A la derecha") { state.align(.right) }
            Divider()
            Button("Arriba") { state.align(.top) }
            Button("Centrar verticalmente") { state.align(.centerY) }
            Button("Abajo") { state.align(.bottom) }
            Divider()
            Button("Distribuir horizontalmente") { state.distribute(.horizontal) }.disabled(many < 3)
            Button("Distribuir verticalmente") { state.distribute(.vertical) }.disabled(many < 3)
        }
        .accessibilityLabel("Alinear y distribuir")
        .help("Un objeto se alinea con la imagen; con Mayús+clic eliges varios y se alinean entre sí.")
    }

    private var presetsMenu: some View {
        Menu("Presets de estilo") {
            ForEach(state.stylePresets.all()) { p in
                Button(p.name) { state.updateStyle { $0 = p.value } }
            }
            Divider()
            Button("Guardar estilo actual…") { field1 = ""; dialog = .stylePreset }
            Menu("Eliminar preset") {
                ForEach(state.stylePresets.all()) { p in
                    Button(p.name) { state.stylePresets.delete(p.name); state.refreshPresets() }
                }
            }
        }
        .accessibilityLabel("Presets de estilo")
    }

    // MARK: Image

    private var imageSection: some View {
        Section("Imagen") {
            HStack {
                Button { state.apply(.rotateLeft) } label: { Image(systemName: "rotate.left") }
                    .help("Girar 90° a la izquierda").accessibilityLabel("Girar 90° a la izquierda")
                Button { state.apply(.rotateRight) } label: { Image(systemName: "rotate.right") }
                    .help("Girar 90° a la derecha").accessibilityLabel("Girar 90° a la derecha")
                Button { state.apply(.flipHorizontal) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Voltear horizontalmente").accessibilityLabel("Voltear horizontalmente")
                Button { state.apply(.flipVertical) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .help("Voltear verticalmente").accessibilityLabel("Voltear verticalmente")
            }
            Button("Redimensionar imagen…") {
                field1 = String(Int(state.document.imageSize.width)); field2 = String(Int(state.document.imageSize.height)); dialog = .resizeImage
            }
            Button("Tamaño del lienzo…") {
                field1 = String(Int(state.document.imageSize.width)); field2 = String(Int(state.document.imageSize.height)); dialog = .resizeCanvas
            }
            Button("Insertar imagen…") {
                if let i = pickImage() { state.insertImage(i) }
            }
            .help("También puedes pegar con ⌘V o arrastrar un archivo al lienzo.")
            Toggle("Borde", isOn: Binding(
                get: { state.document.border != nil },
                set: { state.setBorder($0 ? ImageBorder() : nil) }))
            if let b = state.document.border {
                slider("Grosor del borde", value: Binding(get: { b.width }, set: { v in var n = b; n.width = v; state.setBorder(n) }), range: 1...40)
                ColorPicker("Color del borde", selection: Binding(
                    get: { b.color.swiftUI }, set: { c in var n = b; n.color = EditorColor(c); state.setBorder(n) }), supportsOpacity: false)
            }
            Toggle("Cuadrícula", isOn: $state.showGrid)
            Toggle("Ajustar a la cuadrícula", isOn: $state.snapToGrid)
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        Section("Fondo") {
            Toggle("Añadir fondo", isOn: Binding(
                get: { state.document.background != nil },
                set: { state.setBackground($0 ? BackdropStyle() : nil) }))
            if let bg = state.document.background {
                Toggle("Equilibrio automático", isOn: Binding(get: { bg.autoBalance }, set: { v in update { $0.autoBalance = v } }))
                    .help("Calcula el margen según el tamaño de la captura y la deja centrada.")
                if !bg.autoBalance { slider("Margen", value: edit(\.padding), range: 0...300) }
                ColorPicker("Color de fondo", selection: Binding(
                    get: { bg.color.swiftUI }, set: { c in update { $0.color = EditorColor(c) } }), supportsOpacity: false)
                Toggle("Degradado", isOn: Binding(
                    get: { bg.gradientEnd != nil },
                    set: { on in update { $0.gradientEnd = on ? EditorColor(0.65, 0.35, 0.9) : nil } }))
                if let end = bg.gradientEnd {
                    ColorPicker("Color final del degradado", selection: Binding(
                        get: { end.swiftUI }, set: { c in update { $0.gradientEnd = EditorColor(c) } }), supportsOpacity: false)
                }
                Picker("Patrón", selection: Binding(get: { bg.pattern }, set: { v in update { $0.pattern = v } })) {
                    Text("Ninguno").tag(BackdropPattern?.none)
                    ForEach(BackdropPattern.allCases, id: \.self) { Text(patternName($0)).tag(Optional($0)) }
                }
                Picker("Proporción", selection: Binding(get: { bg.aspect }, set: { v in update { $0.aspect = v } })) {
                    Text("Libre").tag(BackdropAspect?.none)
                    ForEach(BackdropAspect.allCases, id: \.self) { Text(verbatim: $0.label).tag(Optional($0)) }
                }
                HStack {
                    Button("Imagen de fondo…") { if let i = pickImage() { state.setBackgroundImage(i) } }
                    if bg.imageID != nil { Button("Quitar") { state.setBackgroundImage(nil) }.accessibilityLabel("Quitar imagen de fondo") }
                }
                slider("Radio", value: edit(\.cornerRadius), range: 0...60)
                Toggle("Sombra", isOn: Binding(get: { bg.shadow }, set: { s in update { $0.shadow = s } }))
            }
            Menu("Presets de fondo") {
                ForEach(state.backdropPresets.all()) { p in
                    Button(p.name) { state.setBackground(p.value) }
                }
                Divider()
                Button("Guardar fondo actual…") { field1 = ""; dialog = .backdropPreset }
                    .disabled(state.document.background == nil)
                Menu("Eliminar preset") {
                    ForEach(state.backdropPresets.all()) { p in
                        Button(p.name) { state.backdropPresets.delete(p.name); state.refreshPresets() }
                    }
                }
            }
            .accessibilityLabel("Presets de fondo")
        }
    }

    // MARK: Helpers

    private func patternName(_ p: BackdropPattern) -> String {
        switch p {
        case .dots: String(localized: "Puntos")
        case .grid: String(localized: "Cuadrícula")
        case .stripes: String(localized: "Rayas")
        }
    }

    private func pickImage() -> CGImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Elige una imagen")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let img = EditorImageLoader.load(url) else {
            Toast.show(String(localized: "No se pudo abrir la imagen"), symbol: "exclamationmark.triangle")
            return nil
        }
        return img
    }

    private func applySize(_ d: Dialog) {
        let cur = state.document.imageSize
        guard var w = Int(field1.trimmingCharacters(in: .whitespaces)), var h = Int(field2.trimmingCharacters(in: .whitespaces)) else { sizeError = true; return }
        let op: GeometryOp
        if d == .resizeImage {
            // Changing one side keeps the aspect ratio.
            if w != Int(cur.width), h == Int(cur.height) { h = max(1, Int((Double(w) * cur.height / cur.width).rounded())) }
            else if h != Int(cur.height), w == Int(cur.width) { w = max(1, Int((Double(h) * cur.width / cur.height).rounded())) }
            op = .resize(width: w, height: h)
        } else {
            op = .canvas(width: w, height: h, anchor: CGPoint(x: 0.5, y: 0.5), fill: EditorColor(0, 0, 0, 0))
        }
        if !state.apply(op) { sizeError = true }
    }

    private func savePreset(_ d: Dialog) {
        if d == .stylePreset {
            state.stylePresets.save(field1, state.effectiveStyle)
        } else if var bg = state.document.background {
            bg.imageID = nil // a picture belongs to the document, not to a reusable preset
            state.backdropPresets.save(field1, bg)
        }
        state.refreshPresets()
    }

    private func object<V>(_ key: WritableKeyPath<Annotation, V>) -> Binding<V> where V: Equatable {
        Binding(get: { state.selected?[keyPath: key] ?? Annotation(kind: .line, start: .zero, end: .zero)[keyPath: key] },
                set: { v in state.updateObject { $0[keyPath: key] = v } })
    }

    private func update(_ f: (inout BackdropStyle) -> Void) {
        guard var bg = state.document.background else { return }
        f(&bg)
        state.setBackground(bg)
    }

    private func edit(_ key: WritableKeyPath<BackdropStyle, Double>) -> Binding<Double> {
        Binding(get: { state.document.background?[keyPath: key] ?? 0 }, set: { v in update { $0[keyPath: key] = v } })
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range).accessibilityLabel(Text(title))
        }
    }
}
