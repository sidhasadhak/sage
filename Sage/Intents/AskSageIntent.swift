import AppIntents
import Foundation
import SwiftUI

// MARK: - AskSageIntent
//
// Lets the user invoke Sage from Siri ("Hey Siri, ask Sage…"), the
// Shortcuts app, the Action Button on iPhone 15 Pro+, and Apple
// Intelligence (when available). The intent itself does not run the
// LLM — that requires the chat model to be loaded, which can take
// several seconds and several gigabytes of RAM. Instead we hand the
// query off to the running app via a UserDefaults rendezvous and let
// ChatListView open a new conversation pre-populated with the query.
//
// This mirrors the existing voice-recorder → chat hand-off, so there's
// only one routing path to maintain.

struct AskSageIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Sage"
    static var description = IntentDescription(
        "Ask Sage a question about your photos, notes, contacts, calendar, or anything on your mind. Everything is processed on-device."
    )

    /// Bring Sage to the foreground when the intent fires. The query
    /// is too long-running for an in-place result (3B-param LLM), so
    /// we open the app and let it stream into the chat UI.
    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Question",
        description: "What would you like to ask Sage?",
        requestValueDialog: "What's your question?"
    )
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "I didn't catch a question. Try again.")
        }

        // Rendezvous with the app. Stored under a UserDefaults key that
        // SageShortcutBridge consumes on the next foreground transition.
        // Using UserDefaults (not URL schemes) keeps the entire flow
        // local — nothing leaves the device, no URL handlers to register.
        UserDefaults.standard.set(trimmed, forKey: SageShortcutBridge.pendingQueryKey)
        UserDefaults.standard.set(Date(), forKey: SageShortcutBridge.pendingQueryDateKey)

        // Siri reads this back to the user before opening the app.
        return .result(dialog: "Opening Sage…")
    }
}

// MARK: - Shortcuts surface
//
// AppShortcutsProvider makes the intent appear in:
//   • the Shortcuts app's gallery for Sage,
//   • Siri suggestions on the lock screen,
//   • Spotlight when the user types "Ask Sage",
//   • Action Button configuration on supported iPhones.

struct SageShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskSageIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Ask \(.applicationName) about \(\.$query)",
                "Tell \(.applicationName) \(\.$query)"
            ],
            shortTitle: "Ask Sage",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
    }
}

// MARK: - Bridge
//
// Bridges UserDefaults storage (written by AskSageIntent) into the
// running AppContainer's existing voice-chat-query routing. Called
// once on app launch and every time the app comes to the foreground,
// so a Siri invocation is picked up whether Sage was cold-started or
// already running.

enum SageShortcutBridge {
    static let pendingQueryKey = "shortcut.pendingQuery"
    static let pendingQueryDateKey = "shortcut.pendingQueryDate"

    /// Pulls any pending Siri/Shortcut query out of UserDefaults and
    /// hands it to the container's existing chat-routing channel.
    /// Idempotent — clears the keys after consumption so a second
    /// foreground transition won't replay the same query.
    @MainActor
    static func consumePending(into container: AppContainer) {
        let defaults = UserDefaults.standard
        guard let query = defaults.string(forKey: pendingQueryKey),
              !query.isEmpty else { return }

        // Discard queries older than 60 seconds — if the user invoked
        // Siri but never opened the app, we shouldn't surprise them
        // with a stale question on the next launch.
        if let date = defaults.object(forKey: pendingQueryDateKey) as? Date,
           Date().timeIntervalSince(date) > 60 {
            defaults.removeObject(forKey: pendingQueryKey)
            defaults.removeObject(forKey: pendingQueryDateKey)
            return
        }

        defaults.removeObject(forKey: pendingQueryKey)
        defaults.removeObject(forKey: pendingQueryDateKey)
        container.pendingVoiceChatQuery = query
    }
}
