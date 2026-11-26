import Foundation
import CoreML

struct StoredModel: Identifiable, Hashable {
    let id: String
    let url: URL
    var name: String { id }
}

struct RemoteModelPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var models: [StoredModel] = []
    @Published var status: String = ""
    @Published var downloadProgress: Double = 0

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

    func downloadModel(from remoteURL: URL, suggestedName: String? = nil) async {
        let trimmedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialBase = trimmedName.isEmpty
            ? remoteURL.deletingPathExtension().lastPathComponent
            : trimmedName

        do {
            downloadProgress = 0.05
            status = "Downloading \(initialBase)…"

            let (downloadedTemp, response) = try await URLSession.shared.download(from: remoteURL)
            downloadProgress = 0.7

            let suggestedFile = response.suggestedFilename ?? ""
            let resolvedBase: String = {
                if !trimmedName.isEmpty { return trimmedName }
                if !suggestedFile.isEmpty {
                    let stripped = (suggestedFile as NSString).deletingPathExtension
                    if !stripped.isEmpty { return stripped }
                }
                return initialBase
            }()

            let urlExt = remoteURL.pathExtension.lowercased()
            let suggestedExt = (suggestedFile as NSString).pathExtension.lowercased()
            let ext = urlExt.isEmpty ? suggestedExt : urlExt

            if ext == "zip" {
                try await installZippedModel(from: downloadedTemp, named: resolvedBase)
            } else {
                let staged = fm.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext.isEmpty ? "mlpackage" : ext)")
                if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                try fm.moveItem(at: downloadedTemp, to: staged)
                defer { try? fm.removeItem(at: staged) }
                try await compileAndStore(modelURL: staged, named: resolvedBase)
            }

            downloadProgress = 1.0
            status = "Downloaded \(resolvedBase)"
            refresh()
        } catch {
            downloadProgress = 0
            status = "Download failed: \(error.localizedDescription)"
        }
    }

    func delete(_ m: StoredModel) {
        try? fm.removeItem(at: m.url)
        refresh()
    }

    private func installZippedModel(from zipURL: URL, named baseName: String) async throws {
        let extractDir = fm.temporaryDirectory
            .appendingPathComponent("coremeleon_extract_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: extractDir)
            try? fm.removeItem(at: zipURL)
        }

        try unzipArchive(at: zipURL, to: extractDir)

        guard let modelURL = findCoreMLModel(in: extractDir) else {
            throw NSError(
                domain: "Coremeleon.ModelStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Archive did not contain a .mlpackage, .mlmodel, or .mlmodelc."]
            )
        }

        try await compileAndStore(modelURL: modelURL, named: baseName)
    }

    private func compileAndStore(modelURL: URL, named baseName: String) async throws {
        let dest = dir.appendingPathComponent("\(baseName).mlmodelc", isDirectory: true)
        let ext = modelURL.pathExtension.lowercased()

        if ext == "mlmodelc" {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: modelURL, to: dest)
        } else {
            status = "Compiling \(baseName)…"
            let compiled = try await MLModel.compileModel(at: modelURL)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: compiled, to: dest)
        }
    }

    private func findCoreMLModel(in root: URL) -> URL? {
        let targetExts = ["mlpackage", "mlmodel", "mlmodelc"]
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = enumerator?.nextObject() as? URL {
            if targetExts.contains(item.pathExtension.lowercased()) {
                return item
            }
        }
        return nil
    }

    private func unzipArchive(at zipURL: URL, to destination: URL) throws {
        // Requires a zip dependency such as ZIPFoundation (`try fm.unzipItem(at: zipURL, to: destination)`).
        throw NSError(
            domain: "Coremeleon.ModelStore",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Zip extraction requires ZIPFoundation in the project target."]
        )
    }
}