import AppKit
import Combine
import NativeShotKit

/// State of the library window (UI-12): filters, one page-at-a-time result list and the selection.
@MainActor
final class LibraryModel: ObservableObject {
    enum Scope { case library, trash }

    static let pageSize = 120

    @Published var text = "" { didSet { if text != oldValue { reload(debounce: true) } } }
    @Published var type: ArtifactType? { didSet { reload() } }
    @Published var favoritesOnly = false { didSet { reload() } }
    @Published var tag: String? { didSet { reload() } }
    @Published var sourceApp: String? { didSet { reload() } }
    @Published var scope = Scope.library { didSet { selection = nil; extra = []; reload() } }
    @Published private(set) var items: [StoredArtifact] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = true
    @Published var selection: UUID?
    /// HIS bulk actions: further selected items besides `selection` (⌘-click, ⇧-click/arrows, ⌘A).
    @Published var extra = Set<UUID>()
    @Published private(set) var tags: [(name: String, count: Int)] = []
    @Published private(set) var apps: [String] = []

    let library: Library
    private let app: AppController
    private var generation = 0
    private var task: Task<Void, Never>?
    private var loadingMore = false
    private var bag = Set<AnyCancellable>()

    init(library: Library, app: AppController) {
        self.library = library
        self.app = app
        // Dropping the first value: the initial load is explicit; later ones are captures or edits made elsewhere.
        library.$revision.dropFirst().sink { [weak self] _ in self?.reload() }.store(in: &bag)
        reload()
    }

    var isFiltering: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || type != nil || favoritesOnly || tag != nil || sourceApp != nil }
    var selected: StoredArtifact? { items.first { $0.id == selection } }
    var selectedIDs: Set<UUID> { selection.map { extra.union([$0]) } ?? extra }
    var selectedItems: [StoredArtifact] { items.filter { selectedIDs.contains($0.id) } }

    private func query(offset: Int) -> HistoryQuery {
        var q = HistoryQuery(text: text, type: type, favoritesOnly: favoritesOnly, trashedOnly: scope == .trash,
                             limit: Self.pageSize, offset: offset)
        q.tag = tag; q.sourceApp = sourceApp
        return q
    }

    func reload(debounce: Bool = false) {
        task?.cancel()
        generation += 1
        let gen = generation
        isLoading = true
        task = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled, let store = library.store else { isLoading = false; return }
            let q = query(offset: 0)
            let page = (try? await store.search(q)) ?? []
            let n = (try? await store.count(q)) ?? page.count
            let allTags = (try? await store.allTags()) ?? [], allApps = (try? await store.sourceApps()) ?? []
            guard gen == generation else { return }
            items = page; total = n; loadingMore = false; isLoading = false
            tags = allTags; apps = allApps
            if let t = tag, !allTags.contains(where: { $0.name == t }) { tag = nil } // the last item with that tag is gone
            if let s = selection, !page.contains(where: { $0.id == s }) { selection = nil }
            extra = extra.filter { id in page.contains { $0.id == id } }
        }
    }

    /// Called as cells appear; fetches the next page when the user nears the end.
    func loadMoreIfNeeded(at index: Int) {
        guard index >= items.count - 24, items.count < total, !loadingMore, let store = library.store else { return }
        loadingMore = true
        let gen = generation, q = query(offset: items.count)
        Task {
            let page = (try? await store.search(q)) ?? []
            guard gen == generation else { return }
            items += page; loadingMore = false
            if page.isEmpty { total = items.count }
        }
    }

    // MARK: Selection

    func move(_ dx: Int, _ dy: Int, columns: Int, extend: Bool = false) {
        guard !items.isEmpty else { return }
        guard let i = items.firstIndex(where: { $0.id == selection }) else { selection = items[0].id; return }
        let target = items[min(max(i + dx + dy * columns, 0), items.count - 1)].id
        if extend { extra.formUnion([target]) } else { extra = [] }
        selection = target
    }

    /// Plain click selects one; ⌘ toggles; ⇧ selects the range from the current item.
    func click(_ a: StoredArtifact, command: Bool, shift: Bool) {
        if command {
            if selectedIDs.contains(a.id) {
                extra.remove(a.id)
                if selection == a.id { selection = extra.first; if let s = selection { extra.remove(s) } }
            } else { if selection == nil { selection = a.id } else { extra.insert(a.id) } }
        } else if shift, let from = items.firstIndex(where: { $0.id == selection }), let to = items.firstIndex(where: { $0.id == a.id }) {
            extra = Set(items[min(from, to)...max(from, to)].map(\.id)).subtracting([selection!])
        } else {
            extra = []; selection = a.id
        }
    }

    func selectAll() {
        guard let first = items.first else { return }
        if selection == nil { selection = first.id }
        extra = Set(items.map(\.id)).subtracting([selection!])
    }

    // MARK: Actions

    func copy(_ a: StoredArtifact) { app.capture(from: a).map(app.copy) }
    func pin(_ a: StoredArtifact) { app.capture(from: a).map(app.pin) }
    func reveal(_ a: StoredArtifact) { NSWorkspace.shared.activateFileViewerSelecting([library.url(for: a)]) }

    func toggleFavorite(_ a: StoredArtifact) {
        let on = !a.favorite
        if let i = items.firstIndex(of: a) { items[i].favorite = on }
        if favoritesOnly && !on { drop(a) }
        Task { await library.setFavorite(on, for: a.id) }
    }

    // MARK: Bulk actions and tags (HIS)

    func trashSelected() { let ids = selectedIDs; items.filter { ids.contains($0.id) }.forEach(drop); extra = []; Task { await library.trash(Array(ids)) } }
    func restoreSelected() { let ids = selectedIDs; items.filter { ids.contains($0.id) }.forEach(drop); extra = []; Task { await library.restore(Array(ids)) } }

    /// If any selected item is not a favourite they all become favourites; otherwise they all stop being.
    func favoriteSelected() {
        let on = selectedItems.contains { !$0.favorite }, ids = selectedIDs
        Task { for id in ids { await library.setFavorite(on, for: id) } }
    }

    func addTag(_ tag: String, to ids: Set<UUID>) { Task { await library.addTag(tag, to: Array(ids)) } }
    func removeTag(_ tag: String, from ids: Set<UUID>) { Task { await library.removeTag(tag, from: Array(ids)) } }

    /// Asks for a folder, then writes every selected image with the saved export preferences.
    func exportSelected() {
        let items = selectedItems.filter { $0.type == .screenshot }
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Exportar aquí")
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let app = app
        Task {
            var done = 0
            for (i, a) in items.enumerated() {
                Toast.show(String(localized: "Exportando \(i + 1) de \(items.count)…"), symbol: "square.and.arrow.up")
                guard let capture = app.capture(from: a) else { continue }
                let request = ExportSettings.request(folder: folder, app: a.sourceApp)
                let image = capture.image
                if (try? await Task.detached(priority: .userInitiated) { try ExportJob.run(image, request) }.value) != nil { done += 1 }
            }
            Toast.show(done == items.count ? String(localized: "\(done) capturas exportadas")
                                           : String(localized: "\(done) de \(items.count) exportadas"),
                       symbol: done == items.count ? "checkmark.circle" : "exclamationmark.triangle")
        }
    }

    func export(_ a: StoredArtifact) { app.capture(from: a).map { ExportManager.show(image: $0.image, sourceApp: a.sourceApp) } }
    func printItem(_ a: StoredArtifact) { app.capture(from: a).map { PrintAction.print($0.image) } }

    func trash(_ a: StoredArtifact) { drop(a); Task { await library.trash([a.id]) } }
    func restore(_ a: StoredArtifact) { drop(a); Task { await library.restore([a.id]) } }
    func purge(_ a: StoredArtifact) { drop(a); Task { await library.purge([a.id]) } }
    func emptyTrash() { items = []; total = 0; Task { await library.emptyTrash() } }

    /// Removes the row locally and moves the selection to its neighbour, without waiting for the reload.
    private func drop(_ a: StoredArtifact) {
        guard let i = items.firstIndex(where: { $0.id == a.id }) else { return }
        items.remove(at: i); total = max(0, total - 1)
        if selection == a.id { selection = items.isEmpty ? nil : items[min(i, items.count - 1)].id }
    }
}
