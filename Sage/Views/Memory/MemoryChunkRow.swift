import SwiftUI

struct MemoryChunkRow: View {
    let chunk: MemoryChunk
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
        HStack(alignment: .top, spacing: 12) {
            // Source icon
            RoundedRectangle(cornerRadius: 8)
                .fill(iconColor.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: chunk.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(iconColor)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chunk.typeLabel)
                        .font(Theme.captionFont)
                        .fontWeight(.semibold)
                        .foregroundStyle(iconColor)
                        .textCase(.uppercase)

                    Spacer()

                    Text(chunk.updatedAt.relativeString)
                        .font(Theme.captionFont)
                        .foregroundStyle(.tertiary)
                }

                Text(chunk.content)
                    .font(Theme.bodyFont)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                if !chunk.keywords.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(chunk.keywords.prefix(4), id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.tertiarySystemFill))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        switch chunk.sourceType {
        case .photo: return .purple
        case .contact: return .blue
        case .event: return .red
        case .reminder: return .orange
        case .note: return .yellow
        case .conversation: return .green
        case .email: return .teal
        }
    }
}
