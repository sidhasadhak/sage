import SwiftData
import Foundation

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message]

    init(title: String = "New Conversation") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
    }

    var lastMessage: Message? {
        messages.sorted { $0.createdAt < $1.createdAt }.last
    }

    var displayTitle: String {
        if title != "New Conversation" { return title }
        return messages.first(where: { $0.role == .user })?.content.prefix(40).description ?? title
    }
}
