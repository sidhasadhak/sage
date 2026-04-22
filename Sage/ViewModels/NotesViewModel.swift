import Foundation
import SwiftData
import AVFoundation

@Observable
@MainActor
final class NotesViewModel {
    var searchText = ""
    var showNewNoteSheet = false
    var showVoiceRecorder = false
    private(set) var isTranscribing = false

    private let modelContext: ModelContext
    private let indexingService: IndexingService
    private let permissions: PermissionCoordinator

    init(modelContext: ModelContext, indexingService: IndexingService, permissions: PermissionCoordinator) {
        self.modelContext = modelContext
        self.indexingService = indexingService
        self.permissions = permissions
    }

    func createNote(title: String, body: String) -> Note {
        let note = Note(title: title, body: body)
        modelContext.insert(note)
        try? modelContext.save()
        Task { await indexingService.indexNote(note) }
        return note
    }

    func saveNote(_ note: Note, title: String, body: String) {
        note.title = title
        note.body = body
        note.updatedAt = Date()
        try? modelContext.save()
        Task { await indexingService.indexNote(note) }
    }

    func createVoiceNote(audioURL: URL) async -> Note {
        let note = Note(title: "Voice Note", body: "", isVoiceNote: true)
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        note.audioFileRelativePath = audioURL.path.replacingOccurrences(of: docsURL.path + "/", with: "")
        modelContext.insert(note)
        try? modelContext.save()

        isTranscribing = true
        if let transcription = try? await TranscriptionService.shared.transcribe(fileURL: audioURL) {
            note.transcription = transcription
            note.body = transcription
            note.title = "Voice Note – \(shortTitle(from: transcription))"
            try? modelContext.save()
        }
        isTranscribing = false

        Task { await indexingService.indexNote(note) }
        return note
    }

    func createChecklist(title: String, items: [ChecklistItem]) {
        let note = Note(title: title, isVoiceNote: false)
        note.isChecklist = true
        note.checklistData = try? JSONEncoder().encode(items)
        note.body = items.map { ($0.isDone ? "☑ " : "☐ ") + $0.text }.joined(separator: "\n")
        modelContext.insert(note)
        try? modelContext.save()
        Task { await indexNote(note) }
    }

    func indexNote(_ note: Note) async {
        await indexingService.indexNote(note)
    }

    func deleteNote(_ note: Note) {
        if let path = note.audioFileRelativePath {
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fullURL = docsURL.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: fullURL)
        }
        indexingService.removeNoteChunk(note)
        modelContext.delete(note)
        try? modelContext.save()
    }

    func requestVoicePermissionsIfNeeded() async -> Bool {
        if !permissions.isMicrophoneAuthorized || !permissions.isSpeechAuthorized {
            await permissions.requestVoiceNotePermissions()
        }
        return permissions.isMicrophoneAuthorized && permissions.isSpeechAuthorized
    }

    private func shortTitle(from text: String) -> String {
        let words = text.components(separatedBy: .whitespaces).prefix(5).joined(separator: " ")
        return words.isEmpty ? "Untitled" : words
    }
}
