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
    @State private var showNewChecklist = false

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
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if notes.isEmpty {
                        emptyState
                    } else {
                        notesList
                    }
                }

                // Floating mic button — primary capture surface, easier to
                // reach with one-handed use than a top toolbar button.
                voiceFAB
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
            .navigationTitle("Notes")
            .searchable(text: $searchText, prompt: "Search notes")
            .toolbar { toolbar }
            .sheet(isPresented: $showNewNote) {
                NoteEditorView(note: nil, viewModel: viewModel)
            }
            .sheet(isPresented: $showVoiceRecorder) {
                VoiceNoteRecorderView(viewModel: viewModel)
                    .environmentObject(container)
            }
            .sheet(isPresented: $showNewChecklist) {
                ChecklistEditorView(note: nil, viewModel: viewModel)
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
        List {
            ForEach(filteredNotes) { note in
                NavigationLink {
                    NoteEditorView(note: note, viewModel: viewModel)
                        .environmentObject(container)
                } label: {
                    NoteCard(note: note)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        viewModel?.deleteNote(note)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
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
        // Voice has been moved to the bottom-right FAB for one-handed reach.
        // Checklist + new-note remain in the top toolbar.
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                showNewChecklist = true
            } label: {
                Image(systemName: "checklist")
                    .fontWeight(.semibold)
            }

            Button {
                showNewNote = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .fontWeight(.semibold)
            }
        }
    }

    private var voiceFAB: some View {
        Button {
            showVoiceRecorder = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
        }
        .accessibilityLabel("Record voice note")
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
                if note.isChecklist {
                    Image(systemName: "checklist")
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
