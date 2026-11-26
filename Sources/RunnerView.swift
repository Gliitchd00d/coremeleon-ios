import SwiftUI
import CoreML
import PhotosUI
import AVFoundation

enum Compute: String, CaseIterable, Identifiable {
    case all = "All", ne = "Neural Engine", gpu = "GPU", cpu = "CPU"
    var id: String { rawValue }
    var units: MLComputeUnits {
        switch self {
        case .all: return .all
        case .ne: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .cpu: return .cpuOnly
        }
    }
}

struct InputSpec: Identifiable {
    let id: String
    let type: MLFeatureType
    let constraint: MLImageConstraint?
}

struct RunError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(received.file.lastPathComponent)")
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

extension UIImage {
    func normalized() -> UIImage {
        if imageOrientation == .up { return self }
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let f = UIGraphicsImageRendererFormat.default()
        f.scale = 1
        return UIGraphicsImageRenderer(size: px, format: f).image { _ in
            draw(in: CGRect(origin: .zero, size: px))
        }
    }
}

struct MediaInputRow: View {
    let name: String
    @Binding var image: UIImage?
    @Binding var videoURL: URL?

    @State private var item: PhotosPickerItem?
    @State private var videoDuration: Double = 0
    @State private var currentTime: Double = 0
    @State private var generator: AVAssetImageGenerator?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                Label(
                    videoURL != nil ? "Change media for \(name)" : "Pick image or video for \(name)",
                    systemImage: videoURL != nil ? "film" : "photo.on.rectangle"
                )
            }

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if videoURL != nil && videoDuration > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Frame scrubber")
                        Spacer()
                        Text(String(format: "%.2fs / %.2fs", currentTime, videoDuration))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Slider(value: $currentTime, in: 0...videoDuration)
                        .onChange(of: currentTime) { _, newTime in
                            extractFrame(at: newTime)
                        }
                }
            }
        }
        .onChange(of: item) { _, newItem in
            Task { await loadMedia(from: newItem) }
        }
    }

    private func loadMedia(from item: PhotosPickerItem?) async {
        guard let item else { return }

        if let movie = try? await item.loadTransferable(type: MovieFile.self) {
            videoURL = movie.url
            let asset = AVURLAsset(url: movie.url)
            if let dur = try? await asset.load(.duration) {
                videoDuration = max(0, CMTimeGetSeconds(dur))
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            generator = gen
            currentTime = 0
            extractFrame(at: 0)
            return
        }

        if let data = try? await item.loadTransferable(type: Data.self),
           let uiImage = UIImage(data: data) {
            videoURL = nil
            generator = nil
            videoDuration = 0
            image = uiImage
        }
    }

    private func extractFrame(at seconds: Double) {
        guard let generator else { return }
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: cmTime) { cgImage, _, _ in
            if let cgImage {
                Task { @MainActor in
                    self.image = UIImage(cgImage: cgImage)
                }
            }
        }
    }
}

struct RunnerView: View {
    let model: StoredModel
    @State private var compute: Compute = .all
    @State private var mlModel: MLModel?
    @State private var specs: [InputSpec] = []
    @State private var texts: [String: String] = [:]
    @State private var images: [String: UIImage] = [:]
    @State private var videos: [String: URL] = [:]
    @State private var output = ""
    @State private var outImage: UIImage?
    @State private var errorText = ""
    @State private var info = ""
    @State private var busy = false
    @State private var videoTask: Task<Void, Never>?

    private let ciContext = CIContext()

    var hasVideoInput: Bool { !videos.isEmpty }

    var body: some View {
        Form {
            Section("Compute units") {
                Picker("Compute", selection: $compute) {
                    ForEach(Compute.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if !info.isEmpty { Text(info).font(.footnote).foregroundStyle(.secondary) }
            }

            Section("Inputs") {
                ForEach(specs) { spec in
                    switch spec.type {
                    case .image:
                        MediaInputRow(
                            name: spec.id,
                            image: imageBinding(spec.id),
                            videoURL: videoBinding(spec.id)
                        )
                    case .string, .double, .int64:
                        TextField(spec.id, text: textBinding(spec.id))
                    default:
                        Text("\(spec.id): unsupported input type").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(busy && !hasVideoInput ? "Running…" : "Run Single Frame / Image") {
                    Task { await runSingle() }
                }
                .disabled(busy || mlModel == nil)

                if hasVideoInput {
                    if busy {
                        Button("Stop Video Inference", role: .destructive) {
                            videoTask?.cancel()
                            busy = false
                        }
                    } else {
                        Button("Run Full Video (5 FPS)") {
                            videoTask = Task { await runVideo(fps: 5.0) }
                        }
                        .disabled(mlModel == nil)
                    }
                }
            }

            if !output.isEmpty || outImage != nil || !errorText.isEmpty {
                Section("Output") {
                    if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
                    if !output.isEmpty { Text(output).font(.system(.footnote, design: .monospaced)) }
                    if let outImage {
                        Image(uiImage: outImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: compute) { await load() }
        .onDisappear { videoTask?.cancel() }
    }

    private func imageBinding(_ k: String) -> Binding<UIImage?> {
        Binding(get: { images[k] }, set: { images[k] = $0 })
    }
    private func videoBinding(_ k: String) -> Binding<URL?> {
        Binding(get: { videos[k] }, set: { videos[k] = $0 })
    }
    private func textBinding(_ k: String) -> Binding<String> {
        Binding(get: { texts[k] ?? "" }, set: { texts[k] = $0 })
    }

    private func load() async {
        errorText = ""; mlModel = nil
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = compute.units
            let t = Date()
            let m = try await MLModel.load(contentsOf: model.url, configuration: cfg)
            specs = m.modelDescription.inputDescriptionsByName
                .map { InputSpec(id: $0.key, type: $0.value.type, constraint: $0.value.imageConstraint) }
                .sorted { $0.id < $1.id }
            mlModel = m
            info = String(format: "Loaded in %.0f ms", Date().timeIntervalSince(t) * 1000)
        } catch {
            errorText = "Load failed: \(error.localizedDescription)"
        }
    }

    private func runSingle() async {
        guard let m = mlModel else { return }
        busy = true; errorText = ""; output = ""; outImage = nil
        defer { busy = false }
        do {
            try await predictFrame(using: m, overrideImages: images)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runVideo(fps: Double) async {
        guard let m = mlModel, let (videoKey, url) = videos.first else { return }
        busy = true; errorText = ""; output = ""; outImage = nil
        defer { busy = false }

        do {
let asset = AVURLAsset(url: url)
let duration = try await asset.load(.duration)
let totalSeconds = CMTimeGetSeconds(duration)
let step = 1.0 / fps
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
var t: Double = 0
while t <= totalSeconds {
if Task.isCancelled { break }
let cmTime = CMTime(seconds: t, preferredTimescale: 600)
if let (cgImage, _) = try? await generator.image(at: cmTime) {
let frameUI = UIImage(cgImage: cgImage)
images[videoKey] = frameUI
var frameInputs = images
frameInputs[videoKey] = frameUI
try await predictFrame(
using: m,
overrideImages: frameInputs,
header: String(format: "Timestamp: %.2fs / %.2fs", t, totalSeconds)
)
}
t += step
}
} catch {
if !Task.isCancelled {
errorText = error.localizedDescription
}
}
}
private func predictFrame(
using m: MLModel,
overrideImages: [String: UIImage],
header: String? = nil
) async throws {
var dict: [String: MLFeatureValue] = [:]
for s in specs {
switch s.type {
case .image:
guard let cg = overrideImages[s.id]?.normalized().cgImage, let c = s.constraint else {
throw RunError(message: "Pick an image or video for (s.id)")
}
dict[s.id] = try MLFeatureValue(cgImage: cg, constraint: c, options: nil)
case .string: dict[s.id] = MLFeatureValue(string: texts[s.id] ?? "")
case .double: dict[s.id] = MLFeatureValue(double: Double(texts[s.id] ?? "") ?? 0)
case .int64: dict[s.id] = MLFeatureValue(int64: Int64(texts[s.id] ?? "") ?? 0)
default: throw RunError(message: "Input (s.id) has an unsupported type")
}
}
let provider = try MLDictionaryFeatureProvider(dictionary: dict)
let t = Date()
let out = try await m.prediction(from: provider)
let ms = Date().timeIntervalSince(t) * 1000
var lines: [String] = []
if let header { lines.append(header) }
for name in out.featureNames.sorted() {
guard let v = out.featureValue(for: name) else { continue }
switch v.type {
case .string: lines.append("(name): (v.stringValue)")
case .int64: lines.append("(name): (v.int64Value)")
case .double: lines.append("(name): (v.doubleValue)")
case .dictionary:
let top = v.dictionaryValue.sorted { $0.value.doubleValue > $1.value.doubleValue }.prefix(5)
lines.append("(name):")
for (k, p) in top { lines.append("  (k): (String(format: "%.3f", p.doubleValue))") }
case .multiArray:
if let a = v.multiArrayValue {
let n = min(a.count, 8)
let head = (0..<n).map { String(format: "%.4g", a[$0].doubleValue) }.joined(separator: ", ")
lines.append("(name): shape (a.shape.map(.intValue)) [(head)(a.count > n ? ", …" : "")]")
}
case .image:
if let buf = v.imageBufferValue {
let ci = CIImage(cvPixelBuffer: buf)
if let cg = ciContext.createCGImage(ci, from: ci.extent) { outImage = UIImage(cgImage: cg) }
lines.append("(name): image")
}
default: lines.append("(name): unsupported output type")
}
}
lines.append(String(format: "— %.1f ms", ms))
output = lines.joined(separator: "\n")
}
}
