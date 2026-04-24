import SwiftUI
import SwiftData

struct ModelLibraryView: View {
    @EnvironmentObject var container: AppContainer
    @Query var localModels: [LocalModel]

    @State private var selectedCapability: Capability = .all
    @State private var showDeleteConfirm: LocalModel? = nil

    // MARK: - Capability filter

    enum Capability: String, CaseIterable, Identifiable {
        case all           = "All"
        case fast          = "Fast"
        case reasoning     = "Reasoning"
        case vision        = "Vision"
        case multilingual  = "Multilingual"
        case photoAnalysis = "Photo Analysis"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all:           return "square.grid.2x2"
            case .fast:          return "bolt"
            case .reasoning:     return "brain"
            case .vision:        return "eye"
            case .multilingual:  return "globe"
            case .photoAnalysis: return "photo.stack"
            }
        }
    }

    var filteredCatalog: [CatalogModel] {
        switch selectedCapability {
        case .all:
            return ModelCatalog.all
        case .fast:
            return ModelCatalog.all.filter { $0.tags.contains(.fast) || $0.tags.contains(.compact) }
        case .reasoning:
            return ModelCatalog.all.filter { $0.tags.contains(.reasoning) || $0.tags.contains(.capable) }
        case .vision:
            return ModelCatalog.all.filter { $0.isVisionCapable }
        case .multilingual:
            return ModelCatalog.all.filter { $0.tags.contains(.multilingual) }
        case .photoAnalysis:
            return ModelCatalog.photoAnalysis
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                activeModelBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                capabilityFilterBar
                    .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        // Section header for the Photo Analysis filter
                        if selectedCapability == .photoAnalysis {
                            photoAnalysisSectionHeader
                                .padding(.horizontal, 16)
                        }

                        ForEach(filteredCatalog) { model in
                            ModelCard(
                                catalog: model,
                                localModel: localModel(for: model.id),
                                downloadState: container.modelManager.downloads[model.id],
                                isActive: container.modelManager.activeModel?.catalogID == model.id,
                                isLoaded: container.llmService.state == .ready(model.displayName)
                            )
                            .environmentObject(container)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    storageInfo
                }
            }
        }
    }

    // MARK: - Subviews

    private var activeModelBanner: some View {
        Group {
            switch container.llmService.state {
            case .noModelSelected:
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Download a model below to start chatting.")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))

            case .loading(let name):
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading \(name)…")
                        .font(Theme.captionFont)
                    Spacer()
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))

            case .ready(let name):
                HStack(spacing: 10) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("\(name) — ready")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))

            case .generating:
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Generating…")
                        .font(Theme.captionFont)
                    Spacer()
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))

            case .error(let msg):
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(msg).font(Theme.captionFont).foregroundStyle(.red)
                    Spacer()
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            }
        }
    }

    private var capabilityFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Capability.allCases) { cap in
                    FilterChip(
                        label: cap.rawValue,
                        icon: cap.icon,
                        isSelected: selectedCapability == cap
                    ) {
                        selectedCapability = cap
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var photoAnalysisSectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Photo Analysis")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text("Downloads once. Runs at index time to generate rich photo descriptions — any chat model can then search your photos by content.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var storageInfo: some View {
        let totalGB = localModels.reduce(0) { $0 + $1.sizeGB }
        return Text(String(format: "%.1f GB used", totalGB))
            .font(Theme.captionFont)
            .foregroundStyle(.secondary)
    }

    private func localModel(for catalogID: String) -> LocalModel? {
        localModels.first { $0.catalogID == catalogID }
    }
}
