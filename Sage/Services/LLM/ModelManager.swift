import Foundation
import SwiftData
import CryptoKit

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
        case .ready:      return "Ready"
        case .failed:     return error ?? "Failed"
        }
    }
}

// MARK: - ModelManager

/// Manages the two fixed Sage models (chat + photo analysis).
/// Download states are exposed so ModelSetupView can show progress.
@Observable
@MainActor
final class ModelManager {

    // MARK: - State

    /// Live download progress keyed by catalog ID.
    private(set) var downloads: [String: DownloadState] = [:]

    /// The downloaded chat model record (nil = not yet downloaded).
    private(set) var chatModel: LocalModel?

    /// The downloaded photo-analysis model record (nil = not yet downloaded).
    private(set) var photoModel: LocalModel?

    /// True once both models are on disk and ready to load.
    var bothModelsDownloaded: Bool { chatModel != nil && photoModel != nil }

    /// Overall 0–1 progress across both downloads (used by setup screen).
    var overallProgress: Double {
        let chatP  = downloads[ModelCatalog.chatModel.id]?.progress  ?? (chatModel  != nil ? 1.0 : 0.0)
        let photoP = downloads[ModelCatalog.photoAnalysisModel.id]?.progress ?? (photoModel != nil ? 1.0 : 0.0)
        return (chatP + photoP) / 2.0
    }

    var totalStorageGB: Double {
        (chatModel != nil ? ModelCatalog.chatModel.sizeGB : 0)
            + (photoModel != nil ? ModelCatalog.photoAnalysisModel.sizeGB : 0)
    }

    private let modelContext: ModelContext

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        chatModel  = fetchLocalModel(for: ModelCatalog.chatModel.id)
        photoModel = fetchLocalModel(for: ModelCatalog.photoAnalysisModel.id)
    }

    // MARK: - Download

    /// Starts downloading whichever models are not yet on disk.
    func downloadAllModels() {
        startDownloadIfNeeded(ModelCatalog.chatModel,          existing: chatModel)
        startDownloadIfNeeded(ModelCatalog.photoAnalysisModel, existing: photoModel)
    }

    /// Re-download a specific model (deletes the existing record first).
    func redownload(_ catalog: CatalogModel) {
        let existing = catalog.isPhotoAnalysisModel ? photoModel : chatModel
        if let existing {
            try? FileManager.default.removeItem(at: existing.localURL)
            modelContext.delete(existing)
            try? modelContext.save()
            if catalog.isPhotoAnalysisModel { photoModel = nil } else { chatModel = nil }
        }
        startDownload(catalog)
    }

    func cancelDownload(_ catalogID: String) {
        downloads.removeValue(forKey: catalogID)
    }

    // MARK: - Delete

    func delete(_ model: LocalModel) {
        try? FileManager.default.removeItem(at: model.localURL)
        if model.catalogID == ModelCatalog.chatModel.id          { chatModel  = nil }
        if model.catalogID == ModelCatalog.photoAnalysisModel.id { photoModel = nil }
        modelContext.delete(model)
        try? modelContext.save()
    }

    // MARK: - Helpers

    func localModel(for catalogID: String) -> LocalModel? {
        catalogID == ModelCatalog.chatModel.id ? chatModel : photoModel
    }

    // MARK: - Private

    private func startDownloadIfNeeded(_ catalog: CatalogModel, existing: LocalModel?) {
        guard existing == nil, downloads[catalog.id] == nil else { return }
        startDownload(catalog)
    }

    private func startDownload(_ catalog: CatalogModel) {
        downloads[catalog.id] = DownloadState()
        Task { await performDownload(catalog) }
    }

    private func performDownload(_ catalog: CatalogModel) async {
        let destDir = modelsDirectory().appendingPathComponent(catalog.localDirectoryName)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            let filesToDownload = try await fetchFileList(repoID: catalog.id)
            let total = filesToDownload.count

            for (index, file) in filesToDownload.enumerated() {
                let fileURL  = hfRawURL(repoID: catalog.id, filename: file.filename)
                let destFile = destDir.appendingPathComponent(file.filename)

                // Resume support: skip files already on disk *only* if they pass
                // the integrity check. A partially-written file from a prior
                // crash would otherwise be silently treated as valid and the
                // model would later load corrupted weights.
                if FileManager.default.fileExists(atPath: destFile.path) {
                    if try verifyChecksumIfAvailable(at: destFile, expected: file.expectedSHA256) {
                        continue
                    } else {
                        try? FileManager.default.removeItem(at: destFile)
                    }
                }

                downloads[catalog.id]?.phase    = .downloading
                downloads[catalog.id]?.progress = Double(index) / Double(total)

                try await downloadFile(from: fileURL, to: destFile,
                                       catalogID: catalog.id, fileIndex: index, totalFiles: total)

                // Verify SHA-256 against the Hugging Face LFS metadata. Catches
                // truncated downloads, MITM tampering, and HF storage corruption
                // *before* the file is ever fed to MLX. On mismatch we delete
                // the file so a redownload starts cleanly.
                let ok = try verifyChecksumIfAvailable(at: destFile, expected: file.expectedSHA256)
                if !ok {
                    try? FileManager.default.removeItem(at: destFile)
                    throw ModelError.checksumMismatch(file.filename)
                }
            }

            downloads[catalog.id]?.phase = .extracting

            let localModel = LocalModel(
                catalogID: catalog.id,
                displayName: catalog.displayName,
                sizeGB: catalog.sizeGB,
                localDirectory: catalog.localDirectoryName
            )
            modelContext.insert(localModel)
            try? modelContext.save()

            if catalog.isPhotoAnalysisModel { photoModel = localModel } else { chatModel = localModel }
            downloads.removeValue(forKey: catalog.id)

        } catch {
            downloads[catalog.id]?.phase = .failed
            downloads[catalog.id]?.error = error.localizedDescription
        }
    }

    private func fetchLocalModel(for catalogID: String) -> LocalModel? {
        let descriptor = FetchDescriptor<LocalModel>(
            predicate: #Predicate { $0.catalogID == catalogID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func modelsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hfRawURL(repoID: String, filename: String) -> URL {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encoded)")!
    }

    /// Result of `fetchFileList`: filename plus an optional expected SHA-256
    /// drawn from Hugging Face's LFS metadata. Small text files (config.json,
    /// tokenizer.json) are typically not LFS-tracked, so `expectedSHA256`
    /// will be nil and they're trusted via HTTPS only.
    private struct RemoteFile {
        let filename: String
        let expectedSHA256: String?
    }

    private func fetchFileList(repoID: String) async throws -> [RemoteFile] {
        // ?blobs=true asks HF to include LFS blob metadata (oid = SHA-256)
        // for files that are LFS-tracked. Without it, `lfs` is omitted.
        let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true")!
        let (data, _) = try await URLSession.shared.data(from: apiURL)

        struct HFModel: Decodable {
            struct LFS: Decodable { let oid: String? }
            struct Sibling: Decodable {
                let rfilename: String
                let lfs: LFS?
            }
            let siblings: [Sibling]
        }

        let model = try JSONDecoder().decode(HFModel.self, from: data)

        return model.siblings.compactMap { sib -> RemoteFile? in
            let filename = sib.rfilename
            let ext  = (filename as NSString).pathExtension
            let name = (filename as NSString).lastPathComponent
            let keep = ext == "safetensors" ||
                       ext == "json" ||
                       name.hasPrefix("tokenizer") ||
                       name == "special_tokens_map.json" ||
                       name == "generation_config.json"
            guard keep else { return nil }
            // HF LFS oid is the SHA-256 of the original file, hex-encoded.
            return RemoteFile(filename: filename, expectedSHA256: sib.lfs?.oid)
        }
    }

    // MARK: - Checksum verification

    /// Verifies the SHA-256 of `file` matches `expected`. Streams the file in
    /// 1 MB chunks so even multi-GB safetensors are hashed without loading
    /// into memory. Returns `true` if `expected` is nil (nothing to check).
    private nonisolated func verifyChecksumIfAvailable(at file: URL, expected: String?) throws -> Bool {
        guard let expected, !expected.isEmpty else { return true }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20    // 1 MB
        while autoreleasepool(invoking: {
            let data = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex.caseInsensitiveCompare(expected) == .orderedSame
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        catalogID: String,
        fileIndex: Int,
        totalFiles: Int
    ) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelError.downloadFailed("HTTP error for \(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        let fileProgress = Double(fileIndex + 1) / Double(totalFiles)
        downloads[catalogID]?.progress = fileProgress
    }
}

// MARK: - ModelError

enum ModelError: LocalizedError {
    case downloadFailed(String)
    case loadFailed(String)
    case noModelSelected
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .loadFailed(let msg):     return "Could not load model: \(msg)"
        case .noModelSelected:         return "AI model not ready. Please wait for setup to complete."
        case .checksumMismatch(let f): return "Integrity check failed for \(f). The file was deleted; tap retry to redownload."
        }
    }
}
