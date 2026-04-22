import SwiftData
import Foundation

@Model
final class Note {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var isVoiceNote: Bool
    var audioFileRelativePath: String?
    var transcription: String?

    @Relationship(deleteRule: .cascade)
    var memoryChunk: MemoryChunk?

    init(title: String = "", body: String = "", isVoiceNote: Bool = false) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.isVoiceNote = isVoiceNote
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var displayTitle: String {
        title.isEmpty ? (body.prefix(40).description.isEmpty ? "Untitled" : body.prefix(40).description) : title
    }

    var searchableText: String {
        [title, body, transcription ?? ""].joined(separator: " ")
    }
}
