import SwiftUI
import SwiftData
import UIKit

// MARK: - MessageBubble
//
// Renders one chat message. Phase-2 adds a Sources strip beneath
// assistant bubbles when the response cited any retrieved chunks.
// The strip is a horizontal scroller of small chips; tapping a
// chip opens the source via the system URL scheme (photos-redirect,
// calshow, x-apple-reminderkit). For notes / conversations / emails
// (which lack a deep-link scheme), the chip remains informative but
// non-tappable — Phase 7 will route those into in-app viewers.

struct MessageBubble: View {
    let message: Message
    @Environment(\.modelContext) private var modelContext
    @State private var showTimestamp = false

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 60)
            } else {
                SageAvatar()
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(renderedContent)
                    .font(Theme.bodyFont)
                    .foregroundStyle(isUser ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.blue : Theme.aiBubble)
                    .clipShape(BubbleShape(isUser: isUser))

                // Phase-2: Sources strip — only on assistant bubbles
                // where the response cited at least one chunk.
                if !isUser, !message.injectedChunkIDs.isEmpty {
                    SourcesStrip(sourceIDs: message.injectedChunkIDs)
                }

                if showTimestamp {
                    Text(message.createdAt.formatted(.dateTime.hour().minute()))
                        .font(Theme.captionFont)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }

            if !isUser {
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, 2)
        .onTapGesture {
            withAnimation(Theme.easeAnimation) {
                showTimestamp.toggle()
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    /// Inline-styled message text. Citation markers `[c1]..[cN]` are
    /// styled smaller + accent-colored so they read as annotations
    /// rather than literal punctuation. We intentionally keep them
    /// as text rather than tappable buttons here — taps go to the
    /// Sources strip below, which is more discoverable on touch.
    private var renderedContent: AttributedString {
        var attr = AttributedString(message.content)
        let pattern = #"\[\s*[cC]\s*\d+\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attr }
        let plain = message.content
        let range = NSRange(plain.startIndex..., in: plain)
        for m in regex.matches(in: plain, range: range).reversed() {
            guard let r = Range(m.range, in: plain),
                  let attrRange = Range(r, in: attr) else { continue }
            attr[attrRange].foregroundColor = isUser ? .white.opacity(0.7) : .accentColor
            attr[attrRange].font = .caption.weight(.semibold)
        }
        return attr
    }
}

// MARK: - SourcesStrip

private struct SourcesStrip: View {
    let sourceIDs: [String]

    /// Resolved chunks, refetched whenever the sourceID list changes.
    /// We don't use @Query because the predicate depends on a runtime
    /// array; a manual fetch on appear is cheaper and avoids the
    /// dynamic-predicate gymnastics SwiftData currently requires.
    @State private var resolved: [MemoryChunk] = []
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(resolved.enumerated()), id: \.element.id) { index, chunk in
                    Button {
                        if let url = chunk.openURL { UIApplication.shared.open(url) }
                    } label: {
                        HStack(spacing: 4) {
                            Text("[c\(index + 1)]")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Image(systemName: chunk.icon)
                                .font(.caption2)
                            Text(chunk.typeLabel)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: sourceIDs) { await load() }
    }

    private func load() async {
        let ids = Set(sourceIDs)
        guard !ids.isEmpty else { resolved = []; return }
        let descriptor = FetchDescriptor<MemoryChunk>(
            predicate: #Predicate { ids.contains($0.sourceID) }
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        // Preserve the citation order from the response.
        let order = Dictionary(uniqueKeysWithValues: sourceIDs.enumerated().map { ($1, $0) })
        resolved = fetched.sorted { (order[$0.sourceID] ?? .max) < (order[$1.sourceID] ?? .max) }
    }
}

// MARK: - SageAvatar / BubbleShape (unchanged)

struct SageAvatar: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor.gradient)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: "sparkle")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
            }
    }
}

struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18
        let _: CGFloat = 4 // tail radius reserved for future use
        var path = Path()

        if isUser {
            // Rounded rect with small notch bottom-right
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        } else {
            // Rounded rect with small notch bottom-left
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        }

        return path
    }
}
