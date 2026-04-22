import SwiftUI
import SwiftData

struct ModelLibraryView: View {
    @EnvironmentObject var container: AppContainer
    @Query var localModels: [LocalModel]

    @State private var selectedFamily: String? = nil
    @State private var showDeleteConfirm: LocalModel? = nil

    var families: [String] {
        let all = ModelCatalog.all.map(\.family)
        return Array(Set(all)).sorted()
    }

    var filteredCatalog: [CatalogModel] {
        guard let family = selectedFamily else { return ModelCatalog.all }
        return ModelCatalog.all.filter { $0.family == family }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                activeModelBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                familyFilterBar
                    .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(spacing: 12) {
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

    private var familyFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", icon: "square.grid.2x2", isSelected: selectedFamily == nil) {
                    selectedFamily = nil
                }
                ForEach(families, id: \.self) { family in
                    FilterChip(
                        label: family,
                        icon: iconFor(family: family),
                        isSelected: selectedFamily == family
                    ) {
                        selectedFamily = selectedFamily == family ? nil : family
                    }
                }
            }
            .padding(.horizontal, 16)
        }
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

    private func iconFor(family: String) -> String {
        switch family {
        case "Llama": return "l.circle"
        case "Phi": return "p.circle"
        case "Gemma": return "g.circle"
        case "Mistral": return "m.circle"
        case "Qwen": return "q.circle"
        default: return "cpu"
        }
    }
}
