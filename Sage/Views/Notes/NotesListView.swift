import SwiftUI
import SwiftData

struct NotesListView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Note.updatedAt, order: .reverse) var notes: [Note]

    @State private var viewModel: NotesViewModel?
    @State private var searchText = ""
    @State private var showNewNote = false
    @State private var showVoiceRecorder = false

    var filteredNotes: [Note] {
        if searchText.isEmpty { return notes }
        return notes.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText) ||
            $0.body.localizedCaseInsensitiveContains(searchText) ||
            ($0.transcription ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty {
                    emptyState
                } else {
                    notesList
                }
            }
            .navigationTitle("Notes")
            .searchable(text: $searchText, prompt: "Search notes")
            .toolbar { toolbar }
            .sheet(isPresented: $showNewNote) {
                NoteEditorView(note: nil, viewModel: viewModel)
            }
            .sheet(isPresented: $showVoiceRecorder) {
                VoiceNoteRecorderView(viewModel: viewModel)
            }
        }
        .task {
            viewModel = NotesViewModel(
                modelContext: modelContext,
                indexingService: container.indexingService,
                permissions: container.permissions
            )
        }
    }

    private var notesList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredNotes) { note in
                    NavigationLink {
                        NoteEditorView(note: note, viewModel: viewModel)
                    } label: {
                        NoteCard(note: note)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            viewModel?.deleteNote(note)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "note.text")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No notes yet")
                    .font(Theme.titleFont)
                Text("Capture your thoughts by text or voice.\nEverything gets indexed for Sage to reference.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                showVoiceRecorder = true
            } label: {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }

            Button {
                showNewNote = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .fontWeight(.semibold)
            }
        }
    }
}

struct NoteCard: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if note.isVoiceNote {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                Text(note.displayTitle)
                    .font(Theme.headlineFont)
                    .lineLimit(1)

                Spacer()

                Text(note.updatedAt.relativeString)
                    .font(Theme.captionFont)
                    .foregroundStyle(.tertiary)
            }

            if !note.body.isEmpty {
                Text(note.body)
                    .font(Theme.bodyFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(Theme.cardPadding)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}
