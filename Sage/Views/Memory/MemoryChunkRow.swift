import SwiftUI

struct MemoryChunkRow: View {
    let chunk: MemoryChunk
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(alignment: .center, spacing: 8) {
                // Source icon — compact
                RoundedRectangle(cornerRadius: 6)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: chunk.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(iconColor)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(chunk.typeLabel.uppercased())
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(iconColor)
                        Spacer()
                        Text(chunk.updatedAt.relativeString)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(chunk.content)
                        .font(Theme.captionFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        switch chunk.sourceType {
        case .photo:        return .purple
        case .contact:      return .blue
        case .event:        return .red
        case .reminder:     return .orange
        case .note:         return .yellow
        case .conversation: return .green
        case .email:        return .teal
        }
    }
}
