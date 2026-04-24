import Foundation

// Previously used to deep-link into the Models tab. Models tab has been removed.
// Kept so existing notification publishers compile without changes.
extension Notification.Name {
    static let switchToModelsTab = Notification.Name("SageSwitchToModelsTab")
}
