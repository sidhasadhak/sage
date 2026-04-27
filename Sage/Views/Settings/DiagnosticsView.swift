import SwiftUI
import SwiftData
import UIKit

/// In-app diagnostics surface for users (and the developer). Shows what's
/// indexed, what failed, and whether the on-disk model files match what
/// ModelManager expects. Intended to replace the previous "I don't know
/// why my phone is hot" guessing game with hard numbers users can copy
/// into a bug report.
///
/// Read-only by design — no destructive actions live here. The two
/// destructive paths (Clear All Memories, Re-Index) stay in SettingsView
/// where they belong.
struct DiagnosticsView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) private var modelContext

    @State private var chunkCounts: [(MemoryChunk.SourceType, Int)] = []
    @State private var totalChunks: Int = 0
    @State private var quantizedCount: Int = 0
    @State private var legacyCount: Int = 0
    @State private var chatModelFiles: ModelIntegrity = .unknown
    // sage-slim: photoModelFiles state removed with the photo stack.
    @State private var refreshing = false
    @State private var copiedAt: Date?
    @State private var evalReport: EvalReport?
    @State private var evalRunning = false

    enum ModelIntegrity: Equatable {
        case unknown
        case missing
        case present(fileCount: Int, sizeMB: Double)
    }

    var body: some View {
        List {
            indexingSection
            memoryStoreSection
            embeddingsSection
            modelsSection
            recentLogSection
            evalSection
            actionsSection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    // MARK: - Sections

    private var indexingSection: some View {
        Section("Indexing") {
            row("Status", value: container.indexingService.isIndexing ? "Running" : "Idle")
            row("Total chunks", value: "\(totalChunks)")
            row("Live counter", value: "\(container.indexingService.indexedCount)")
            if let date = container.indexingService.lastIndexedAt {
                row("Last completed", value: date.formatted(date: .abbreviated, time: .shortened))
            } else {
                row("Last completed", value: "Never")
            }
            if let err = container.indexingService.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Last error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var memoryStoreSection: some View {
        Section("Memory store") {
            if chunkCounts.isEmpty {
                row("No chunks yet", value: "")
            } else {
                ForEach(chunkCounts, id: \.0) { type, count in
                    row(type.rawValue.capitalized, value: "\(count)")
                }
            }
        }
    }

    private var embeddingsSection: some View {
        Section {
            row("Quantized (int8)", value: "\(quantizedCount)")
            row("Legacy (Float32)", value: "\(legacyCount)")
            if legacyCount > 0 {
                Text("Legacy chunks will be re-packed on next launch (one-time, automatic).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Embedding format")
        } footer: {
            // Rough storage estimate: int8 ≈ 520 B / vector, Float32 ≈ 2048 B.
            let bytes = quantizedCount * 520 + legacyCount * 2048
            Text("Approx. on-disk vector storage: \(byteFormat(bytes))")
        }
    }

    private var modelsSection: some View {
        Section("Models") {
            modelRow(name: "Chat", integrity: chatModelFiles, model: container.modelManager.chatModel)
            // sage-slim: Photo Vision row removed.
            row("LLM state", value: llmStateString)
        }
    }

    private var recentLogSection: some View {
        Section {
            let log = container.indexingService.recentLog
            if log.isEmpty {
                Text("No events yet — run an indexing pass to see entries here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: severityIcon(entry.severity))
                            .foregroundStyle(severityColor(entry.severity))
                            .font(.caption)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.caption)
                                .textSelection(.enabled)
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Recent events")
        } footer: {
            Text("Last \(IndexingService.logCapacity) entries, newest first.")
        }
    }

    // Retrieval regression harness. Runs the seed query pack through
    // SemanticSearchEngine and reports pass-rate@5 / @10 / MRR. The
    // numbers themselves matter less than the delta between two runs:
    // a 30-point drop after a code change is the signal to look for.
    private var evalSection: some View {
        Section {
            Button {
                Task { await runEval() }
            } label: {
                HStack {
                    Label(evalRunning ? "Running…" : "Run retrieval eval",
                          systemImage: "checkmark.seal")
                    Spacer()
                    if evalRunning { ProgressView().scaleEffect(0.7) }
                }
            }
            .disabled(evalRunning)

            if let report = evalReport {
                row("Queries", value: "\(report.totalQueries)")
                row("Pass@5",  value: percentString(report.passRateAt5))
                row("Pass@10", value: percentString(report.passRateAt10))
                row("MRR",     value: String(format: "%.3f", report.meanReciprocalRank))

                DisclosureGroup("Per-query results") {
                    ForEach(report.perQuery) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(result.query).font(.caption)
                                Spacer()
                                if let rank = result.firstHitRank {
                                    Text("hit @\(rank)")
                                        .font(.caption2)
                                        .foregroundStyle(rank <= 5 ? .green : .orange)
                                } else {
                                    Text("miss")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            ForEach(Array(result.topResultsPreview.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        } header: {
            Text("Retrieval eval")
        } footer: {
            Text("Runs \(RetrievalEval.seedQueries.count) generic queries through search and reports pass-rates. Use as a regression check after retrieval changes — re-run before and after to measure impact.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                copyDiagnostics()
            } label: {
                HStack {
                    Label("Copy diagnostics to clipboard", systemImage: "doc.on.doc")
                    Spacer()
                    if let copiedAt, Date().timeIntervalSince(copiedAt) < 2 {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                }
            }

            Button {
                Task { await refresh() }
            } label: {
                HStack {
                    Label("Refresh", systemImage: "arrow.clockwise")
                    Spacer()
                    if refreshing { ProgressView().scaleEffect(0.7) }
                }
            }
        }
    }

    // MARK: - Row helpers

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func modelRow(name: String, integrity: ModelIntegrity, model: LocalModel?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Group {
                    switch integrity {
                    case .unknown:
                        Text("—").foregroundStyle(.secondary)
                    case .missing:
                        Label("Missing", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    case .present(let count, let mb):
                        Label("\(count) files · \(String(format: "%.0f", mb)) MB",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }
            if let model {
                Text(model.catalogID)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private var llmStateString: String {
        switch container.llmService.state {
        case .ready: return "Ready"
        case .loading(let n): return "Loading \(n)"
        case .generating: return "Generating"
        case .error: return "Error"
        case .noModelSelected: return "Not loaded"
        }
    }

    private func severityIcon(_ s: IndexingLogEntry.Severity) -> String {
        switch s {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func severityColor(_ s: IndexingLogEntry.Severity) -> Color {
        switch s {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func byteFormat(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1_000
        return String(format: "%.0f KB", kb)
    }

    // MARK: - Eval

    private func runEval() async {
        evalRunning = true
        defer { evalRunning = false }
        evalReport = await container.retrievalEval.run()
    }

    private func percentString(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100)
    }

    // MARK: - Refresh

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }

        // 1. Chunk counts grouped by source type. One fetch, in-memory group.
        let descriptor = FetchDescriptor<MemoryChunk>()
        let chunks = (try? modelContext.fetch(descriptor)) ?? []
        totalChunks = chunks.count

        var grouped: [MemoryChunk.SourceType: Int] = [:]
        var quant = 0
        var legacy = 0
        for chunk in chunks {
            grouped[chunk.sourceType, default: 0] += 1
            if let data = chunk.embeddingData {
                if Self.looksQuantized(data) { quant += 1 } else { legacy += 1 }
            }
        }
        // Iterate every SourceType (including .contact, which the Memory tab
        // hides but Diagnostics still counts) so storage totals are honest.
        let allTypes: [MemoryChunk.SourceType] =
            [.photo, .contact, .event, .reminder, .note, .conversation, .email]
        chunkCounts = allTypes.compactMap { type in grouped[type].map { (type, $0) } }
        quantizedCount = quant
        legacyCount = legacy

        // 2. Model file integrity. Walk the on-disk directory; report
        // file count + size. We don't re-verify SHA here (expensive on
        // multi-GB safetensors). That's the download-time check.
        chatModelFiles = integrity(of: container.modelManager.chatModel)
        // sage-slim: photo model integrity check removed.
    }

    private func integrity(of model: LocalModel?) -> ModelIntegrity {
        guard let model else { return .missing }
        let url = model.localURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ), !entries.isEmpty else {
            return .missing
        }
        let totalBytes = entries.reduce(into: Int64(0)) { sum, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sum += Int64(size)
        }
        return .present(fileCount: entries.count, sizeMB: Double(totalBytes) / 1_000_000)
    }

    // MARK: - Clipboard

    private func copyDiagnostics() {
        var lines: [String] = []
        lines.append("Sage Diagnostics — \(Date().formatted())")
        lines.append("Version: \(Bundle.main.appVersion)")
        lines.append("")
        lines.append("INDEXING")
        lines.append("  Status: \(container.indexingService.isIndexing ? "running" : "idle")")
        lines.append("  Total chunks: \(totalChunks)")
        if let date = container.indexingService.lastIndexedAt {
            lines.append("  Last completed: \(date.formatted())")
        }
        if let err = container.indexingService.lastError {
            lines.append("  Last error: \(err)")
        }
        lines.append("")
        lines.append("MEMORY STORE")
        for (type, count) in chunkCounts {
            lines.append("  \(type.rawValue): \(count)")
        }
        lines.append("")
        lines.append("EMBEDDINGS")
        lines.append("  Quantized: \(quantizedCount)")
        lines.append("  Legacy:    \(legacyCount)")
        lines.append("")
        lines.append("MODELS")
        lines.append("  Chat:  \(integrityString(chatModelFiles))")
        // sage-slim: photo model line removed.
        lines.append("  LLM:   \(llmStateString)")
        lines.append("")
        lines.append("RECENT EVENTS")
        for entry in container.indexingService.recentLog.reversed().prefix(20) {
            let stamp = entry.date.formatted(date: .omitted, time: .standard)
            lines.append("  [\(stamp)] [\(entry.severity)] \(entry.message)")
        }

        UIPasteboard.general.string = lines.joined(separator: "\n")
        copiedAt = Date()
    }

    private func integrityString(_ i: ModelIntegrity) -> String {
        switch i {
        case .unknown: return "unknown"
        case .missing: return "missing"
        case .present(let c, let mb): return "\(c) files, \(String(format: "%.0f", mb)) MB"
        }
    }
}

extension DiagnosticsView {
    /// Local copy of the int8-quantization magic-byte sniff. Kept inline so
    /// this view doesn't depend on quickwin/02-persist-embeddings landing
    /// first; on the baseline (no quantized writes yet), every blob is
    /// correctly reported as legacy Float32.
    static func looksQuantized(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic: [UInt8] = [0x51, 0x38, 0x00, 0x01]    // "Q8\0\1"
        return data.prefix(4).elementsEqual(magic)
    }
}
