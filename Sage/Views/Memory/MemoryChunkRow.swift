import SwiftUI

// MARK: - MemoryChunkRow
//
// One row in the memory browser. Phase-2 adds three user-driven
// memory controls via context-menu + swipe actions:
//
//   • Pin     — chunk is elevated to .longTerm and never decays.
//   • Forget  — removes from SwiftData, search cache, Spotlight.
//                Source data (photo, contact, event) is untouched.
//   • Correct — opens an inline editor; bumps confidence to 1.0.
//
// All three route through `MemoryDecay` (read from the environment)
// so the audit log captures user intent.

struct MemoryChunkRow: View {
    let chunk: MemoryChunk
    var onTap: (() -> Void)? = nil

    @EnvironmentObject var container: AppContainer
    @State private var showCorrect = false
    @State private var correctedText = ""

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
                    HStack(spacing: 6) {
                        Text(chunk.typeLabel.uppercased())
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(iconColor)
                        if chunk.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.accentColor)
                        }
                        if chunk.tier == .ephemeral {
                            Text("aged")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
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
        .contextMenu { memoryControls }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await forget() }
            } label: {
                Label("Forget", systemImage: "trash")
            }
            Button {
                togglePin()
            } label: {
                Label(chunk.pinned ? "Unpin" : "Pin",
                      systemImage: chunk.pinned ? "pin.slash" : "pin.fill")
            }
            .tint(.accentColor)
        }
        .sheet(isPresented: $showCorrect) {
            CorrectChunkSheet(
                originalContent: chunk.content,
                onSave: { newText in
                    container.memoryDecay?.correct(chunk, newContent: newText)
                    showCorrect = false
                },
                onCancel: { showCorrect = false }
            )
        }
    }

    @ViewBuilder
    private var memoryControls: some View {
        Button { togglePin() } label: {
            Label(chunk.pinned ? "Unpin" : "Pin",
                  systemImage: chunk.pinned ? "pin.slash" : "pin.fill")
        }
        Button {
            correctedText = chunk.content
            showCorrect = true
        } label: {
            Label("Correct…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            Task { await forget() }
        } label: {
            Label("Forget", systemImage: "trash")
        }
    }

    private func togglePin() {
        let decay = container.memoryDecay
        if chunk.pinned { decay.unpin(chunk) } else { decay.pin(chunk) }
    }

    private func forget() async {
        await container.memoryDecay.forget(chunk)
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

// MARK: - CorrectChunkSheet

private struct CorrectChunkSheet: View {
    let originalContent: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit how Sage remembers this. Your original source (photo, note, event) isn't touched — only Sage's memory of it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .focused($focused)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(minHeight: 180)
            }
            .padding()
            .navigationTitle("Correct Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                text = originalContent
                focused = true
            }
        }
        .presentationDetents([.medium])
    }
}
