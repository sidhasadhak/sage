import SwiftData
import Foundation

@Model
final class ImportedEmail {
    var id: UUID
    var subject: String
    var sender: String
    var senderEmail: String
    var body: String
    var receivedAt: Date
    var importedAt: Date

    @Relationship(deleteRule: .cascade)
    var memoryChunk: MemoryChunk?

    init(subject: String, sender: String, senderEmail: String, body: String, receivedAt: Date) {
        self.id = UUID()
        self.subject = subject
        self.sender = sender
        self.senderEmail = senderEmail
        self.body = body
        self.receivedAt = receivedAt
        self.importedAt = Date()
    }
}
