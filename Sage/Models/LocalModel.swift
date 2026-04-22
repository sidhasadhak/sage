import SwiftData
import Foundation

@Model
final class LocalModel {
    var id: UUID
    var catalogID: String           // matches CatalogModel.id (HuggingFace repo ID)
    var displayName: String
    var sizeGB: Double
    var downloadedAt: Date
    var isActive: Bool
    var localDirectory: String      // relative path inside Documents/Models/

    init(catalogID: String, displayName: String, sizeGB: Double, localDirectory: String) {
        self.id = UUID()
        self.catalogID = catalogID
        self.displayName = displayName
        self.sizeGB = sizeGB
        self.downloadedAt = Date()
        self.isActive = false
        self.localDirectory = localDirectory
    }

    var localURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Models").appendingPathComponent(localDirectory)
    }

    var sizeString: String {
        String(format: "%.1f GB", sizeGB)
    }
}
