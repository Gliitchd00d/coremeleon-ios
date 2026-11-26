import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ModelStore
    @State private var importing = false
    @State private var showingDownloader = false

    var body: some View {
        NavigationStack {
            List {
                if store.models.isEmpty {
                    Text("No models yet. Tap + to import from Files or download a CoreML model.")
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
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.status).font(.footnote)
                            if store.downloadProgress > 0 && store.downloadProgress < 1 {
                                ProgressView(value: store.downloadProgress)
                            }
                        }
                    }
                }
                Section("Version info") {
                    LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                    LabeledContent("Codename", value: AppInfo.codename)
                }
            }
            .navigationTitle("Coremeleon")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingDownloader = true } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    Button { importing = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingDownloader) {
                ModelDownloadSheet()
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

private struct ModelDownloadSheet: View {
    @EnvironmentObject var store: ModelStore
    @Environment(\.dismiss) private var dismiss

    @State private var modelName = ""
    @State private var urlString = ""
    @State private var isDownloading = false

    private let presets: [RemoteModelPreset] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Model URL (.zip, .mlpackage, .mlmodel)") {
                    TextField("Model name (optional)", text: $modelName)
                    TextField("https://.../model.zip", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if !presets.isEmpty {
                    Section("Presets") {
                        ForEach(presets) { preset in
                            Button {
                                Task {
                                    isDownloading = true
                                    await store.downloadModel(from: preset.url, suggestedName: preset.name)
                                    isDownloading = false
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                    Text(preset.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .disabled(isDownloading)
                        }
                    }
                }
            }
            .navigationTitle("Download Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDownloading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isDownloading ? "Downloading…" : "Download") {
                        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            store.status = "Invalid URL"
                            return
                        }
                        Task {
                            isDownloading = true
                            await store.downloadModel(from: url, suggestedName: modelName)
                            isDownloading = false
                            dismiss()
                        }
                    }
                    .disabled(isDownloading || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}