import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ModelStore
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                if store.models.isEmpty {
                    Text("No models yet. Tap + to import a .mlmodel, .mlpackage or .mlmodelc from Files.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.models) { m in
                    NavigationLink(m.name) { RunnerView(model: m) }
                }
                .onDelete { idx in
                    let targets = idx.map { store.models[$0] }
                    targets.forEach { store.delete($0) }
                }
                if !store.status.isEmpty {
                    Section { Text(store.status).font(.footnote) }
                }
                Section("Version info") {
                    LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                    LabeledContent("Codename", value: AppInfo.codename)
                }
            }
            .navigationTitle("Coremeleon")
            .toolbar {
                Button { importing = true } label: { Image(systemName: "plus") }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { for u in urls { await store.importModel(from: u) } }
                }
            }
        }
    }
}
