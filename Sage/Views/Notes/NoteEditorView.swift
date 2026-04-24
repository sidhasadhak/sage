import SwiftUI
import SwiftData

struct NoteEditorView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var container: AppContainer

    let note: Note?
    var viewModel: NotesViewModel?

    @State private var title = ""
    @State private var bodyText = ""
    @FocusState private var bodyFocused: Bool

    var isNew: Bool { note == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Title", text: $title)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    Divider()
                        .padding(.horizontal, 20)

                    if note?.isVoiceNote == true {
                        voiceNoteHeader
                    }

                    TextEditor(text: $bodyText)
                        .font(Theme.bodyFont)
                        .frame(minHeight: 300)
                        .padding(.horizontal, 16)
                        .focused($bodyFocused)
                        .scrollDisabled(true)
                }
            }
            .navigationTitle(isNew ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.isEmpty && bodyText.isEmpty)
                }
            }
            .onAppear {
                title = note?.title ?? ""
                bodyText = note?.body ?? ""
                if isNew { bodyFocused = true }
            }
        }
    }

    private var voiceNoteHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
            Text("Voice Note")
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private func save() {
        if let viewModel {
            // Standard path: viewModel handles save + re-index.
            if let note {
                viewModel.saveNote(note, title: title, body: bodyText)
            } else {
                _ = viewModel.createNote(title: title, body: bodyText)
            }
        } else {
            // Fallback path: opened from Memory tab without a viewModel (e.g. MemoryBrowserView).
            // Persist directly and re-index so changes are not silently discarded.
            if let note {
                note.title = title
                note.body = bodyText
                note.updatedAt = Date()
                try? modelContext.save()
                Task { await container.indexingService.indexNote(note) }
            } else {
                let note = Note(title: title, body: bodyText)
                modelContext.insert(note)
                try? modelContext.save()
                Task { await container.indexingService.indexNote(note) }
            }
        }
        dismiss()
    }
}
