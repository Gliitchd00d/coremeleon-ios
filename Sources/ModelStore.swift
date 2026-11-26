import Foundation
import CoreML

struct StoredModel: Identifiable, Hashable {
    let id: String
    let url: URL
    var name: String { id }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var models: [StoredModel] = []
    @Published var status: String = ""

    private let fm = FileManager.default
    private var dir: URL {
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() { refresh() }

    func refresh() {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        models = items
            .filter { $0.pathExtension == "mlmodelc" }
            .map { StoredModel(id: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.id < $1.id }
    }

    func importModel(from src: URL) async {
        let accessed = src.startAccessingSecurityScopedResource()
        defer { if accessed { src.stopAccessingSecurityScopedResource() } }
        do {
            let ext = src.pathExtension.lowercased()
            let base = src.deletingPathExtension().lastPathComponent
            let dest = dir.appendingPathComponent(base + ".mlmodelc")
            if ext == "mlmodelc" {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
            } else if ext == "mlmodel" || ext == "mlpackage" {
                status = "Compiling \(base)…"
                let tmp = fm.temporaryDirectory.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
                try fm.copyItem(at: src, to: tmp)
                let compiled = try await MLModel.compileModel(at: tmp)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.moveItem(at: compiled, to: dest)
                try? fm.removeItem(at: tmp)
            } else {
                status = "Unsupported file type: .\(ext)"
                return
            }
            status = "Imported \(base)"
            refresh()
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    func delete(_ m: StoredModel) {
        try? fm.removeItem(at: m.url)
        refresh()
    }
}
