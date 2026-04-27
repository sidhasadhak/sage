import SwiftUI

/// Shown on first launch (or after a re-download) while the two fixed models are being fetched.
/// Disappears automatically once both models are on disk.
struct ModelSetupView: View {
    @EnvironmentObject var container: AppContainer

    private var chatDownload: DownloadState? { container.modelManager.downloads[ModelCatalog.chatModel.id] }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App identity
            VStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.accentColor)

                Text("Setting up Sage")
                    .font(.system(.title, design: .rounded, weight: .bold))

                Text("Downloading your private AI models.\nEverything stays on your device — nothing is ever sent to the cloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // sage-slim: single chat model — photo download row removed.
            VStack(spacing: 16) {
                ModelDownloadRow(
                    name: ModelCatalog.chatModel.displayName,
                    description: "General-purpose chat & reasoning",
                    icon: "bubble.left.and.bubble.right.fill",
                    iconColor: .blue,
                    sizeGB: ModelCatalog.chatModel.sizeGB,
                    isComplete: container.modelManager.chatModel != nil,
                    downloadState: chatDownload
                )
            }
            .padding(.horizontal, 24)

            // Overall progress
            VStack(spacing: 8) {
                ProgressView(value: container.modelManager.overallProgress)
                    .tint(.accentColor)
                    .padding(.horizontal, 24)

                Text(String(format: "%.1f GB · Wi-Fi recommended", ModelCatalog.chatModel.sizeGB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            container.modelManager.downloadAllModels()
        }
    }
}

// MARK: - Row

private struct ModelDownloadRow: View {
    let name: String
    let description: String
    let icon: String
    let iconColor: Color
    let sizeGB: Double
    let isComplete: Bool
    let downloadState: DownloadState?

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            RoundedRectangle(cornerRadius: 10)
                .fill(iconColor.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(iconColor)
                }

            // Labels
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.subheadline, weight: .semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status
            statusBadge
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isComplete {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        } else if let state = downloadState {
            VStack(alignment: .trailing, spacing: 4) {
                switch state.phase {
                case .downloading:
                    ProgressView(value: state.progress)
                        .tint(iconColor)
                        .frame(width: 64)
                    Text(state.progressString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .extracting:
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("Processing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                default:
                    EmptyView()
                }
            }
        } else {
            Text(String(format: "%.1f GB", sizeGB))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
