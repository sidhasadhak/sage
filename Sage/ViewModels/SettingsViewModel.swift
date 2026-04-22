import Foundation
import SwiftUI

enum AppColorScheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.stars"
        }
    }
}

@Observable
@MainActor
final class SettingsViewModel {
    var showIndexConfirmation = false
    var showClearMemoryConfirmation = false
    private(set) var indexingProgress: String = ""

    var colorScheme: AppColorScheme {
        get {
            let raw = UserDefaults.standard.string(forKey: "app_color_scheme") ?? AppColorScheme.system.rawValue
            return AppColorScheme(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "app_color_scheme")
        }
    }

    private let permissions: PermissionCoordinator
    private let indexingService: IndexingService
    private let searchEngine: SemanticSearchEngine
    private let spotlightService: SpotlightService

    init(
        permissions: PermissionCoordinator,
        indexingService: IndexingService,
        searchEngine: SemanticSearchEngine,
        spotlightService: SpotlightService
    ) {
        self.permissions = permissions
        self.indexingService = indexingService
        self.searchEngine = searchEngine
        self.spotlightService = spotlightService
    }

    var permissionsGranted: [String: Bool] {
        [
            "Photos": permissions.isPhotosAuthorized,
            "Contacts": permissions.isContactsAuthorized,
            "Calendar": permissions.isCalendarAuthorized,
            "Reminders": permissions.isReminderAuthorized,
            "Microphone": permissions.isMicrophoneAuthorized,
            "Speech": permissions.isSpeechAuthorized
        ]
    }

    func runFullIndex() async {
        await indexingService.indexAll()
    }

    func clearAllMemory() async {
        await searchEngine.invalidateCache()
        await spotlightService.removeAll()
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

import UIKit
