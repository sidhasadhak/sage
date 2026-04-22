import Foundation

struct ChecklistItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var isDone: Bool = false
}
