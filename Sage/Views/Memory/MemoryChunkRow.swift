import SwiftUI

struct MemoryChunkRow: View {
    let chunk: MemoryChunk
    var onTap: (() -> Void)? = nil

    @AppStorage("knowledge_graph_enabled") private var graphEnabled = false

    private var displayEntities: [EntityPill.Model] {
        (chunk.entities ?? []).prefix(3).compactMap { raw -> EntityPill.Model? in
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return EntityPill.Model(type: parts[0], name: parts[1])
        }
    }

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

                VStack(alignment: .leading, spacing: 3) {
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

                    // Entity edge badges — only when graph is enabled and entities exist
                    if graphEnabled && !displayEntities.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(displayEntities, id: \.name) { entity in
                                EntityPill(model: entity)
                            }
                        }
                    }
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

// MARK: - Entity edge pill

struct EntityPill: View {
    struct Model {
        let type: String   // "person", "place", "project", "organization", "concept"
        let name: String
    }

    let model: Model

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(model.name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private var icon: String {
        switch model.type {
        case "person":       return "person.fill"
        case "place":        return "mappin.fill"
        case "project":      return "folder.fill"
        case "organization": return "building.2.fill"
        default:             return "circle.fill"
        }
    }

    private var color: Color {
        switch model.type {
        case "person":       return Theme.teal
        case "place":        return .orange
        case "project":      return .indigo
        case "organization": return .blue
        default:             return .secondary
        }
    }
}
