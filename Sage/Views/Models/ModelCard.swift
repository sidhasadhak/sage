import SwiftUI

struct ModelCard: View {
    @EnvironmentObject var container: AppContainer

    let catalog: CatalogModel
    let localModel: LocalModel?
    let downloadState: DownloadState?
    let isActive: Bool
    let isLoaded: Bool

    private var isDownloaded: Bool { localModel != nil }
    private var isDownloading: Bool { downloadState != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                familyIcon
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(catalog.displayName)
                            .font(Theme.headlineFont)
                        if isActive {
                            activeBadge
                        }
                    }
                    Text(catalog.description)
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(14)

            // Stats row
            HStack(spacing: 0) {
                statCell(label: "Size", value: String(format: "%.1f GB", catalog.sizeGB))
                Divider().frame(height: 28)
                statCell(label: "Params", value: catalog.parameterCount)
                Divider().frame(height: 28)
                statCell(label: "Quant", value: catalog.quantization)
                Divider().frame(height: 28)
                statCell(label: "Context", value: contextString)
            }
            .background(Color(.tertiarySystemFill))

            // Tags
            if !catalog.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(catalog.tags, id: \.self) { tag in
                            tagView(tag)
                        }
                        if catalog.isLargeModel {
                            Text("Needs 8GB RAM")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            // Download / activate controls
            controlsRow
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(isActive ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)
    }

    // MARK: - Subviews

    private var familyIcon: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(familyColor.opacity(0.15))
            .frame(width: 42, height: 42)
            .overlay {
                Text(catalog.family.prefix(1))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(familyColor)
            }
    }

    private var activeBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(.green).frame(width: 5, height: 5)
            Text(isLoaded ? "Loaded" : "Active")
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.12))
        .foregroundStyle(.green)
        .clipShape(Capsule())
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func tagView(_ tag: CatalogModel.Tag) -> some View {
        let (color, icon): (Color, String) = switch tag {
        case .recommended: (.accentColor, "star.fill")
        case .fast: (.green, "hare.fill")
        case .capable: (.purple, "brain.fill")
        case .multilingual: (.orange, "globe")
        case .compact: (.teal, "smallcircle.filled.circle")
        case .reasoning: (.indigo, "lightbulb.fill")
        }

        return HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(tag.rawValue).font(.caption2).fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var controlsRow: some View {
        if let state = downloadState {
            // Actively downloading
            VStack(spacing: 6) {
                HStack {
                    Text(state.phase == .extracting ? "Processing…" : "Downloading…")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(state.progressString)
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: state.progress)
                    .tint(.accentColor)
                Button("Cancel") {
                    container.modelManager.cancelDownload(catalog.id)
                }
                .font(Theme.captionFont)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else if let local = localModel {
            // Downloaded — show activate / delete
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    container.modelManager.delete(local)
                    if isActive { Task { await container.llmService.unloadModel() } }
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Spacer()

                if isActive {
                    Button("Unload") {
                        container.modelManager.deactivate()
                        Task { await container.llmService.unloadModel() }
                    }
                    .buttonStyle(SageButtonStyle(filled: false))
                    .controlSize(.small)
                } else {
                    Button("Use This Model") {
                        container.modelManager.setActive(local)
                        Task { await container.llmService.loadModel(from: local) }
                    }
                    .buttonStyle(SageButtonStyle(filled: true))
                    .controlSize(.small)
                }
            }
        } else {
            // Not downloaded
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free to download")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                    Text("~\(String(format: "%.1f GB", catalog.sizeGB)) on device")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    container.modelManager.download(catalog)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(SageButtonStyle(filled: true))
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private var familyColor: Color {
        switch catalog.family {
        case "Llama": return .blue
        case "Phi": return .purple
        case "Gemma": return .green
        case "Mistral": return .orange
        case "Qwen": return .red
        case "SmolLM": return .teal
        default: return .accentColor
        }
    }

    private var contextString: String {
        let k = catalog.contextLength / 1000
        return "\(k)K"
    }
}
