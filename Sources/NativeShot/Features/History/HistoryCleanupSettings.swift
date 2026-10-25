import SwiftUI

/// UI-17 additions: trash retention and cleanup. Embedded in the "Historial" section of the settings.
struct HistoryCleanupSettings: View {
    @ObservedObject var library: Library
    @AppStorage(Prefs.trashRetentionDays) private var trashDays = 30
    @State private var confirmIndex = false
    @State private var confirmTrash = false

    var body: some View {
        Picker("Vaciar la papelera tras", selection: $trashDays) {
            Text("7 días").tag(7); Text("30 días").tag(30); Text("90 días").tag(90); Text("Nunca").tag(0)
        }
        Text("Los favoritos quedan exentos del borrado automático por antigüedad o cantidad. Si envías un favorito a la papelera, se vaciará con ella.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Borrar índice de texto…") { confirmIndex = true }
            .confirmationDialog("¿Borrar el índice de texto?", isPresented: $confirmIndex) {
                Button("Borrar índice", role: .destructive) { Task { await library.clearTextIndex() } }
            } message: {
                Text("Las capturas se conservan, pero dejarán de encontrarse por el texto que contienen.")
            }
        Button("Vaciar la papelera ahora…") { confirmTrash = true }
            .confirmationDialog("¿Vaciar la papelera?", isPresented: $confirmTrash) {
                Button("Vaciar papelera", role: .destructive) { Task { await library.emptyTrash() } }
            } message: {
                Text("Se borrarán los archivos de la papelera. Esta acción no se puede deshacer.")
            }
    }
}
