import SwiftUI
import SwiftData
import UIKit

struct MemoryBrowserView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Query(sort: \MemoryChunk.updatedAt, order: .reverse) var allChunks: [MemoryChunk]
    @Query var notes: [Note]

    @State private var viewModel: MemoryViewModel?
    @State private var searchText = ""
    @State private var selectedType: MemoryChunk.SourceType? = nil
    @State private var isSearching = false
    @State private var selectedNote: Note?

    var displayedChunks: [MemoryChunk] {
        var chunks = allChunks
        if let type = selectedType {
            chunks = chunks.filter { $0.sourceType == type }
        }
        if !searchText.isEmpty {
            chunks = chunks.filter {
                $0.content.localizedCaseInsensitiveContains(searchText) ||
                $0.keywords.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return chunks
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                typeFilterBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                if displayedChunks.isEmpty {
                    emptyState
                } else {
                    chunkList
                }
            }
            .navigationTitle("Memory")
            .searchable(text: $searchText, prompt: "Search your memories")
            .onChange(of: searchText) { _, query in
                Task { await viewModel?.search() }
            }
        }
        .sheet(item: $selectedNote) { note in
            NoteEditorView(note: note, viewModel: nil)
        }
        .task {
            viewModel = MemoryViewModel(
                searchEngine: container.searchEngine,
                modelContext: modelContext
            )
        }
    }

    private var typeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", icon: "square.grid.2x2", isSelected: selectedType == nil) {
                    selectedType = nil
                }
                ForEach(MemoryChunk.SourceType.allCases, id: \.self) { type in
                    FilterChip(
                        label: type.rawValue.capitalized,
                        icon: iconFor(type),
                        isSelected: selectedType == type
                    ) {
                        selectedType = selectedType == type ? nil : type
                    }
                }
            }
        }
    }

    private var chunkList: some View {
        List {
            ForEach(displayedChunks) { chunk in
                MemoryChunkRow(chunk: chunk, onTap: { openChunk(chunk) })
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel?.deleteChunk(chunk)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }

    private func openChunk(_ chunk: MemoryChunk) {
        switch chunk.sourceType {
        case .photo:
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        case .event:
            let interval = Date().timeIntervalSinceReferenceDate
            if let url = URL(string: "calshow:\(interval)") {
                UIApplication.shared.open(url)
            }
        case .reminder:
            if let url = URL(string: "x-apple-reminderkit://") {
                UIApplication.shared.open(url)
            }
        case .contact:
            if let url = URL(string: "addressbook://") {
                UIApplication.shared.open(url)
            }
        case .note:
            selectedNote = notes.first { $0.memoryChunk?.id == chunk.id }
        case .conversation, .email:
            break
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text(allChunks.isEmpty ? "No memories indexed yet" : "No results")
                .font(Theme.titleFont)
                .foregroundStyle(.secondary)

            if allChunks.isEmpty {
                Text("Go to Settings to index your photos, contacts, and calendar.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconFor(_ type: MemoryChunk.SourceType) -> String {
        switch type {
        case .photo: return "photo"
        case .contact: return "person.circle"
        case .event: return "calendar"
        case .reminder: return "checklist"
        case .note: return "note.text"
        case .conversation: return "bubble.left"
        case .email: return "envelope"
        }
    }
}

extension MemoryChunk.SourceType: CaseIterable {
    public static var allCases: [MemoryChunk.SourceType] = [
        .photo, .contact, .event, .reminder, .note, .conversation, .email
    ]
}

struct FilterChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(Theme.captionFont)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .animation(Theme.easeAnimation, value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
