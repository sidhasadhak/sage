import Foundation
import UIKit

// MARK: - App Group identifier
//
// IMPORTANT: This string must match exactly in both the Sage app target and
// the SageShare extension target. After changing it here, update
// Sage/Services/Index/SharedContentIndexer.swift to match.
//
// Setup steps (one-time, in Xcode):
//   1. Select the Sage target → Signing & Capabilities → + Capability → App Groups
//      Add group ID: group.sage.app  (or your own reverse-DNS string)
//   2. Repeat for the SageShare target — use the exact same group ID.
//   3. Both targets must be signed with the same team.
//
// Until App Groups is configured the store silently no-ops — the extension
// posts a user-facing error banner and the main app never picks up shares.

let appGroupID = "group.sage.app"

// MARK: - SharedItem

/// Lightweight, Codable record written by the extension and consumed by the
/// main app's SharedContentIndexer. Deliberately has no SwiftData dependency.
struct SharedItem: Codable, Identifiable {
    enum ItemType: String, Codable {
        case url, text, image
    }

    let id: UUID
    let type: ItemType
    /// URL string, plain text, or a relative path inside SharedImages/.
    let content: String
    /// Optional note the user added in the share sheet.
    let note: String
    let sourceApp: String
    let date: Date

    init(type: ItemType, content: String, note: String = "", sourceApp: String = "") {
        self.id         = UUID()
        self.type       = type
        self.content    = content
        self.note       = note
        self.sourceApp  = sourceApp
        self.date       = Date()
    }
}

// MARK: - Store

/// Reads and writes the pending-shares JSON file inside the shared App Group
/// container. Thread-safe: all mutations are serialised via a private DispatchQueue.
final class SharedItemStore {

    static let shared = SharedItemStore()

    private let queue = DispatchQueue(label: "sage.sharedItemStore", qos: .utility)
    private let fileName = "pending_shares.json"
    private let imageDir = "SharedImages"

    private var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private var pendingURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    private var imagesURL: URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent(imageDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Write (extension side)

    /// Append a new item to the pending list. Safe to call on any thread.
    func append(_ item: SharedItem) {
        queue.sync {
            var items = readAll()
            items.append(item)
            write(items)
        }
    }

    /// Save a UIImage to the shared images directory and return its relative
    /// filename so it can be stored in a SharedItem.content field.
    func saveImage(_ image: UIImage) -> String? {
        guard let dir = imagesURL else { return nil }
        let name = UUID().uuidString + ".jpg"
        let url = dir.appendingPathComponent(name)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        try? data.write(to: url)
        return name
    }

    // MARK: Read + consume (main app side)

    /// Return all pending items and atomically clear the store.
    func drainAll() -> [SharedItem] {
        queue.sync {
            let items = readAll()
            if !items.isEmpty { write([]) }
            return items
        }
    }

    /// Absolute URL for an image filename produced by `saveImage(_:)`.
    func imageURL(for filename: String) -> URL? {
        imagesURL?.appendingPathComponent(filename)
    }

    /// Delete an image file after the main app has indexed it.
    func deleteImage(filename: String) {
        guard let url = imageURL(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Private

    private func readAll() -> [SharedItem] {
        guard let url = pendingURL,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([SharedItem].self, from: data) else {
            return []
        }
        return items
    }

    private func write(_ items: [SharedItem]) {
        guard let url = pendingURL,
              let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
