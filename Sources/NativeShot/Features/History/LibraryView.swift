import SwiftUI
import ImageIO
import NativeShotKit

/// UI-12: grid of thumbnails with native search, filters, internal trash and per-item actions.
struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @FocusState private var gridFocused: Bool
    @State private var searchFocus = 0
    @State private var confirmEmpty = false
    @State private var confirmPurge: StoredArtifact?
    @State private var tagEditor = false

    private static let cell: CGFloat = 168, spacing: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(Button("") { searchFocus += 1 }.keyboardShortcut("f").opacity(0).accessibilityHidden(true))
        .confirmationDialog("¿Vaciar la papelera?", isPresented: $confirmEmpty) {
            Button("Vaciar papelera", role: .destructive) { model.emptyTrash() }
        } message: {
            Text("Se borrarán \(model.total) elementos y sus archivos. Esta acción no se puede deshacer.")
        }
        .confirmationDialog("¿Eliminar definitivamente?", isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } })) {
            Button("Eliminar definitivamente", role: .destructive) { confirmPurge.map(model.purge); confirmPurge = nil }
        } message: {
            Text("Se borrará el archivo original. Esta acción no se puede deshacer.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            SearchField(text: $model.text, focusToken: searchFocus, prompt: String(localized: "Buscar por nombre o texto"))
                .frame(minWidth: 180)
            Picker("Tipo", selection: $model.type) {
                Text("Todos").tag(ArtifactType?.none)
                Text("Capturas").tag(ArtifactType?.some(.screenshot))
                Text("Vídeos").tag(ArtifactType?.some(.video))
                Text("GIF").tag(ArtifactType?.some(.gif))
                Text("Proyectos").tag(ArtifactType?.some(.project))
            }
            .labelsHidden().frame(width: 110)
            .accessibilityLabel("Filtrar por tipo")
            filterMenu
            Toggle(isOn: $model.favoritesOnly) { Image(systemName: model.favoritesOnly ? "star.fill" : "star") }
                .toggleStyle(.button)
                .help("Solo favoritos")
                .accessibilityLabel("Solo favoritos")
            Picker("Vista", selection: $model.scope) {
                Text("Biblioteca").tag(LibraryModel.Scope.library)
                Text("Papelera").tag(LibraryModel.Scope.trash)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            .accessibilityLabel("Vista")
        }
        .padding(10)
    }

    /// HIS: filter by user tag and by the app the capture came from.
    private var filterMenu: some View {
        Menu {
            Picker("Etiqueta", selection: $model.tag) {
                Text("Todas las etiquetas").tag(String?.none)
                ForEach(model.tags, id: \.name) { t in Text("\(t.name) (\(t.count))").tag(String?.some(t.name)) }
            }
            Picker("Aplicación de origen", selection: $model.sourceApp) {
                Text("Cualquier aplicación").tag(String?.none)
                ForEach(model.apps, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        } label: {
            Image(systemName: model.tag != nil || model.sourceApp != nil ? "tag.fill" : "tag")
        }
        .menuIndicator(.hidden).fixedSize()
        .help("Filtrar por etiqueta o aplicación")
        .accessibilityLabel("Filtrar por etiqueta o aplicación")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.library.store == nil {
            ContentUnavailableView("No se pudo abrir la biblioteca", systemImage: "exclamationmark.triangle",
                                   description: Text("El índice no está disponible. Reinicia NativeShot."))
        } else if model.items.isEmpty {
            if model.isLoading {
                ProgressView("Cargando…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isFiltering {
                ContentUnavailableView.search(text: model.text)
            } else if model.scope == .trash {
                ContentUnavailableView("La papelera está vacía", systemImage: "trash")
            } else {
                ContentUnavailableView("Todavía no hay capturas", systemImage: "photo.on.rectangle",
                                       description: Text("Las capturas que hagas aparecerán aquí."))
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let columns = max(1, Int((geo.size.width - 24 + Self.spacing) / (Self.cell + Self.spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.spacing), count: columns),
                              spacing: Self.spacing) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, a in
                            LibraryCell(artifact: a, root: model.library.root, selected: model.selectedIDs.contains(a.id))
                                .id(a.id)
                                .onTapGesture {
                                    let m = NSEvent.modifierFlags
                                    model.click(a, command: m.contains(.command), shift: m.contains(.shift)); gridFocused = true
                                }
                                .onTapGesture(count: 2) { model.copy(a) }
                                .contextMenu { menu(for: a) }
                                .accessibilityActions { menu(for: a) }
                                .onAppear { model.loadMoreIfNeeded(at: index) }
                        }
                    }
                    .padding(12)
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { handle($0, columns: columns) }
                .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
                .accessibilityLabel("Cuadrícula de capturas")
            }
        }
    }

    // MARK: Actions (context menu, VoiceOver actions)

    @ViewBuilder private func menu(for a: StoredArtifact) -> some View {
        if model.selectedIDs.count > 1, model.selectedIDs.contains(a.id) {
            let n = model.selectedIDs.count
            if model.scope == .trash {
                Button("Restaurar \(n) elementos") { model.restoreSelected() }
            } else {
                Button("Favorito para \(n) elementos") { model.favoriteSelected() }
                Button("Etiquetar \(n) elementos…") { tagEditor = true }
                Button("Exportar \(n) elementos…") { model.exportSelected() }
                Divider()
                Button("Mover \(n) elementos a la papelera", role: .destructive) { model.trashSelected() }
            }
        } else if model.scope == .trash {
            Button("Restaurar") { model.restore(a) }
            Button("Eliminar definitivamente…", role: .destructive) { confirmPurge = a }
        } else {
            Button("Copiar") { model.copy(a) }
            Button("Fijar") { model.pin(a) }
            Button("Mostrar en Finder") { model.reveal(a) }
            Button("Exportar…") { model.export(a) }
            Button("Imprimir…") { model.printItem(a) }
            Menu("Abrir con") {
                ForEach(OpenWith.apps(for: model.library.url(for: a))) { app in
                    Button(app.name) { OpenWith.open(model.library.url(for: a), with: app) }
                }
            }
            Button("Etiquetas…") { model.selection = a.id; model.extra = []; tagEditor = true }
            Button(a.favorite ? "Quitar de favoritos" : "Añadir a favoritos") { model.toggleFavorite(a) }
            Divider()
            Button("Mover a la papelera", role: .destructive) { model.trash(a) }
        }
    }

    /// Keyboard: arrows move, Return/⌘C copy, P pin, R reveal, F favorite, ⌫ trash (or restore-less purge in the trash).
    private func handle(_ press: KeyPress, columns: Int) -> KeyPress.Result {
        switch press.key {
        case .leftArrow: model.move(-1, 0, columns: columns, extend: press.modifiers.contains(.shift))
        case .rightArrow: model.move(1, 0, columns: columns, extend: press.modifiers.contains(.shift))
        case .upArrow: model.move(0, -1, columns: columns, extend: press.modifiers.contains(.shift))
        case .downArrow: model.move(0, 1, columns: columns, extend: press.modifiers.contains(.shift))
        default:
            guard let a = model.selected else { return .ignored }
            let key = press.characters.lowercased()
            if press.modifiers == .command, key == "a" { model.selectAll() }
            else if model.selectedIDs.count > 1, press.key == .delete || press.key == .deleteForward {
                if model.scope == .library { model.trashSelected() } else { return .ignored }
            } else if model.scope == .library, press.modifiers.isEmpty, key == "t" { tagEditor = true }
            else if press.key == .return || (press.modifiers == .command && key == "c") {
                if model.scope == .trash { model.restore(a) } else { model.copy(a) }
            } else if press.key == .delete || press.key == .deleteForward {
                if model.scope == .trash { confirmPurge = a } else { model.trash(a) }
            } else if model.scope == .library, press.modifiers.isEmpty, key == "p" { model.pin(a) }
            else if model.scope == .library, press.modifiers.isEmpty, key == "r" { model.reveal(a) }
            else if model.scope == .library, press.modifiers.isEmpty, key == "f" { model.toggleFavorite(a) }
            else { return .ignored }
        }
        return .handled
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(model.scope == .trash ? "\(model.total) en la papelera" : "\(model.total) elementos")
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.scope == .trash ? "\(model.total) elementos en la papelera" : "\(model.total) elementos")
            Spacer()
            if model.scope == .trash {
                Button("Vaciar papelera…", role: .destructive) { confirmEmpty = true }.disabled(model.total == 0)
            } else if model.selectedIDs.count > 1 {
                Text("\(model.selectedIDs.count) seleccionados").foregroundStyle(.secondary)
                Button("Favorito") { model.favoriteSelected() }
                Button("Etiquetar…") { tagEditor = true }
                    .popover(isPresented: $tagEditor) { TagEditor(model: model, ids: model.selectedIDs) }
                Button("Exportar…") { model.exportSelected() }
                Button { model.trashSelected() } label: { Image(systemName: "trash") }
                    .help("Mover a la papelera (⌫)")
                    .accessibilityLabel("Mover la selección a la papelera")
            } else if let a = model.selected {
                Button("Etiquetas…") { tagEditor = true }
                    .help("Etiquetas (T)")
                    .popover(isPresented: $tagEditor) { TagEditor(model: model, ids: [a.id]) }
                Button("Copiar") { model.copy(a) }.help("Copiar (⌘C o Intro)")
                Button("Fijar") { model.pin(a) }.help("Fijar (P)")
                Button("Mostrar en Finder") { model.reveal(a) }.help("Mostrar en Finder (R)")
                Button { model.toggleFavorite(a) } label: { Image(systemName: a.favorite ? "star.fill" : "star") }
                    .help("Favorito (F)")
                    .accessibilityLabel(a.favorite ? "Quitar de favoritos" : "Añadir a favoritos")
                Button { model.trash(a) } label: { Image(systemName: "trash") }
                    .help("Mover a la papelera (⌫)")
                    .accessibilityLabel("Mover a la papelera")
            }
        }
        .padding(10)
    }
}

// MARK: Cell

private struct LibraryCell: View {
    let artifact: StoredArtifact
    let root: URL
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 160, height: 110)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                if artifact.favorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).padding(5)
                }
            }
            Text(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .task(id: artifact.id) { image = await ThumbnailLoader.load(artifact, root: root) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var label: String {
        let app = artifact.sourceApp.map { String(localized: " de \($0)") } ?? ""
        let fav = artifact.favorite ? String(localized: ", favorita") : ""
        return String(localized: "Captura \(app), \(artifact.createdAt.formatted(date: .complete, time: .shortened)), \(artifact.width) por \(artifact.height) píxeles") + fav
    }
}

/// Reads `thumbnails/<uuid>.jpg`, creating it first for items captured before thumbnails existed.
enum ThumbnailLoader {
    private nonisolated(unsafe) static let cache: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>(); c.countLimit = 600; return c
    }()

    @MainActor static func load(_ a: StoredArtifact, root: URL) async -> NSImage? {
        if let hit = cache.object(forKey: a.id as NSUUID) { return hit }
        let thumb = Thumbnails.url(for: a.id, root: root), original = root.appendingPathComponent(a.originalPath)
        if a.type == .video, !FileManager.default.fileExists(atPath: thumb.path) {
            await Library.writePoster(of: original, to: thumb) // recordings made before posters existed
        }
        let cg: CGImage? = await Task.detached(priority: .utility) {
            if !FileManager.default.fileExists(atPath: thumb.path) { try? Thumbnails.generate(from: original, to: thumb) }
            return CGImageSourceCreateWithURL(thumb as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }.value
        guard let cg, !Task.isCancelled else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(img, forKey: a.id as NSUUID)
        return img
    }
}

// MARK: Native search field

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.setAccessibilityLabel(String(localized: "Buscar en la biblioteca"))
        f.delegate = context.coordinator
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.token != focusToken {
            context.coordinator.token = focusToken
            f.window?.makeFirstResponder(f)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var token: Int
        init(_ p: SearchField) { parent = p; token = p.focusToken }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSSearchField { parent.text = f.stringValue }
        }
    }
}

// MARK: Tags

/// Add or remove user tags for one or several items. Typing a tag and pressing Return adds it.
private struct TagEditor: View {
    @ObservedObject var model: LibraryModel
    let ids: Set<UUID>
    @State private var draft = ""
    @State private var current: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ids.count > 1 ? "Etiquetas para \(ids.count) elementos" : "Etiquetas").font(.headline)
            TextField("Nueva etiqueta", text: $draft)
                .onSubmit(add)
                .accessibilityLabel("Nueva etiqueta")
            if !current.isEmpty {
                FlowTags(tags: current, symbol: "xmark.circle.fill", label: "Quitar la etiqueta") { tag in
                    model.removeTag(tag, from: ids); current.removeAll { $0 == tag }
                }
            }
            let others = model.tags.map(\.name).filter { !current.contains($0) }
            if !others.isEmpty {
                Text("Usadas antes").font(.caption).foregroundStyle(.secondary)
                FlowTags(tags: others, symbol: "plus.circle", label: "Añadir la etiqueta") { tag in
                    model.addTag(tag, to: ids); current.append(tag)
                }
            }
        }
        .padding(14).frame(width: 280)
        .task { await load() }
    }

    /// Tags shared by every selected item.
    private func load() async {
        var shared: Set<String>?
        for id in ids {
            let t = Set(await model.library.tags(for: id))
            shared = shared.map { $0.intersection(t) } ?? t
        }
        current = (shared ?? []).sorted()
    }

    private func add() {
        guard let t = HistoryStore.normalizeTag(draft) else { return }
        model.addTag(t, to: ids)
        if !current.contains(t) { current.append(t); current.sort() }
        draft = ""
    }
}

private struct FlowTags: View {
    let tags: [String]
    let symbol: String
    let label: LocalizedStringKey
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { t in
                Button { action(t) } label: { Label(t, systemImage: symbol).labelStyle(.titleAndIcon) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel(Text("\(t)"))
                    .accessibilityHint(Text(label))
            }
        }
    }
}
