import SwiftData
import Foundation

@Model
final class Message {
    var id: UUID
    var role: Role
    var content: String
    var createdAt: Date
    var conversation: Conversation?
    var injectedChunkIDs: [String]

    enum Role: String, Codable {
        case user, assistant
    }

    init(role: Role, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = Date()
        self.injectedChunkIDs = []
    }
}
