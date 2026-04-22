import Foundation
import SwiftData

// Tracks per-model download state
struct DownloadState {
    enum Phase { case downloading, extracting, ready, failed }
    var phase: Phase = .downloading
    var progress: Double = 0      // 0.0 – 1.0
    var error: String?
    var bytesTotal: Int64 = 0
    var bytesReceived: Int64 = 0

    var progressString: String {
        switch phase {
        case .downloading:
            if bytesTotal > 0 {
                let mb = Double(bytesReceived) / 1_000_000
                let total = Double(bytesTotal) / 1_000_000
                return String(format: "%.0f / %.0f MB", mb, total)
            }
            return "\(Int(progress * 100))%"
        case .extracting: return "Processing…"
        case .ready: return "Ready"
        case .failed: return error ?? "Failed"
        }
    }
}

@Observable
@MainActor
final class ModelManager {

    private(set) var downloads: [String: DownloadState] = [:]    // catalogID -> state
    private(set) var activeModel: LocalModel?
    private(set) var loadedModelID: String?     // currently loaded in RAM

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        activeModel = fetchActiveModel()
    }

    // MARK: - Download

    func download(_ catalog: CatalogModel) {
        guard downloads[catalog.id] == nil else { return }
        downloads[catalog.id] = DownloadState()

        Task {
            await performDownload(catalog)
        }
    }

    func cancelDownload(_ catalogID: String) {
        downloads.removeValue(forKey: catalogID)
        // Note: actual URLSession task cancellation would be wired here in a full impl
    }

    private func performDownload(_ catalog: CatalogModel) async {
        let destDir = modelsDirectory().appendingPathComponent(catalog.localDirectoryName)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Download each required file from HuggingFace raw content
            // MLX models consist of: config.json, tokenizer files, model weights (.safetensors)
            let filesToDownload = try await fetchFileList(repoID: catalog.id)
            let total = filesToDownload.count

            for (index, filename) in filesToDownload.enumerated() {
                let fileURL = hfRawURL(repoID: catalog.id, filename: filename)
                let destFile = destDir.appendingPathComponent(filename)

                // Skip already-downloaded files (resume support)
                if FileManager.default.fileExists(atPath: destFile.path) { continue }

                downloads[catalog.id]?.phase = .downloading
                downloads[catalog.id]?.progress = Double(index) / Double(total)

                try await downloadFile(from: fileURL, to: destFile, catalogID: catalog.id,
                                       fileIndex: index, totalFiles: total)
            }

            downloads[catalog.id]?.phase = .extracting

            // Create LocalModel record
            let localModel = LocalModel(
                catalogID: catalog.id,
                displayName: catalog.displayName,
                sizeGB: catalog.sizeGB,
                localDirectory: catalog.localDirectoryName
            )
            modelContext.insert(localModel)
            try modelContext.save()

            downloads.removeValue(forKey: catalog.id)

        } catch {
            downloads[catalog.id]?.phase = .failed
            downloads[catalog.id]?.error = error.localizedDescription
        }
    }

    // MARK: - Activation

    func setActive(_ model: LocalModel) {
        // Deactivate all others
        let all = (try? modelContext.fetch(FetchDescriptor<LocalModel>())) ?? []
        for m in all { m.isActive = false }
        model.isActive = true
        activeModel = model
        try? modelContext.save()
    }

    func deactivate() {
        let all = (try? modelContext.fetch(FetchDescriptor<LocalModel>())) ?? []
        for m in all { m.isActive = false }
        activeModel = nil
        try? modelContext.save()
    }

    // MARK: - Delete

    func delete(_ model: LocalModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        if model.isActive { activeModel = nil }
        modelContext.delete(model)
        try? modelContext.save()
    }

    // MARK: - State helpers

    func isDownloaded(_ catalogID: String) -> Bool {
        let descriptor = FetchDescriptor<LocalModel>(
            predicate: #Predicate { $0.catalogID == catalogID }
        )
        return (try? modelContext.fetch(descriptor).first) != nil
    }

    func localModel(for catalogID: String) -> LocalModel? {
        let descriptor = FetchDescriptor<LocalModel>(
            predicate: #Predicate { $0.catalogID == catalogID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func downloadedModels() -> [LocalModel] {
        (try? modelContext.fetch(FetchDescriptor<LocalModel>())) ?? []
    }

    // MARK: - Private helpers

    private func fetchActiveModel() -> LocalModel? {
        let descriptor = FetchDescriptor<LocalModel>(
            predicate: #Predicate { $0.isActive == true }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func modelsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hfRawURL(repoID: String, filename: String) -> URL {
        // HuggingFace CDN URL pattern
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encoded)")!
    }

    // Fetch model file list from HuggingFace API
    private func fetchFileList(repoID: String) async throws -> [String] {
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID)")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)

        struct HFModel: Decodable {
            struct Sibling: Decodable { let rfilename: String }
            let siblings: [Sibling]
        }

        let model = try JSONDecoder().decode(HFModel.self, from: data)

        // Only download files needed for MLX inference
        let needed = model.siblings.map(\.rfilename).filter { filename in
            let ext = (filename as NSString).pathExtension
            let name = (filename as NSString).lastPathComponent
            return ext == "safetensors" ||
                   ext == "json" ||
                   name.hasPrefix("tokenizer") ||
                   name == "special_tokens_map.json" ||
                   name == "generation_config.json"
        }
        return needed
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        catalogID: String,
        fileIndex: Int,
        totalFiles: Int
    ) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ModelError.downloadFailed("HTTP error for \(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        let fileProgress = Double(fileIndex + 1) / Double(totalFiles)
        downloads[catalogID]?.progress = fileProgress
    }
}

enum ModelError: LocalizedError {
    case downloadFailed(String)
    case loadFailed(String)
    case noModelSelected

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .loadFailed(let msg): return "Could not load model: \(msg)"
        case .noModelSelected: return "No model selected. Go to Models tab to download one."
        }
    }
}
