import Foundation

// MARK: - ActionRegistry
//
// Central catalogue mapping a router-emitted intent name (snake_case)
// to a builder closure that constructs a typed `AnyAction`. Builders
// capture the services they need at registration time.
//
// The registry is the *only* place new actions get wired in — adding
// one is exactly two changes:
//   1. Implement the `Action` protocol in Concrete/.
//   2. Register a builder here.
//
// Anything outside the registry interacts with `AnyAction` only.

@MainActor
final class ActionRegistry {

    // Builder takes the raw [String: String] params from the router
    // and returns a fully-constructed AnyAction (or throws).
    typealias Builder = @MainActor ([String: String]) throws -> AnyAction

    private var builders: [String: Builder] = [:]

    /// Display labels for each registered action. Powers the
    /// "What can Sage do?" surface in Settings (Phase 7).
    private(set) var displayNames: [String: String] = [:]

    init(
        reminderService: ReminderCreationService,
        calendarService: CalendarEventCreationService
    ) {
        register(name: CreateReminderAction.name,
                 displayName: CreateReminderAction.displayName) { params in
            let a = try CreateReminderAction(rawParameters: params, service: reminderService)
            return AnyAction(a)
        }

        register(name: CreateEventAction.name,
                 displayName: CreateEventAction.displayName) { params in
            let a = try CreateEventAction(rawParameters: params, service: calendarService)
            return AnyAction(a)
        }

        register(name: EditEventAction.name,
                 displayName: EditEventAction.displayName) { params in
            let a = try EditEventAction(rawParameters: params)
            return AnyAction(a)
        }

        register(name: RunShortcutAction.name,
                 displayName: RunShortcutAction.displayName) { params in
            let a = try RunShortcutAction(rawParameters: params)
            return AnyAction(a)
        }
    }

    // MARK: - Public

    /// Returns true when an intent name is registered. Used by the
    /// chat view model to decide whether to trust a `.action`
    /// classification or fall back to the chat path.
    func canHandle(_ intent: String) -> Bool {
        builders[intent] != nil
    }

    /// Construct an action from a router-emitted plan. Throws
    /// `ActionError.unknownAction` for unregistered names and
    /// whatever the action's init throws (missing/invalid params).
    func make(intent: String, parameters: [String: String]) throws -> AnyAction {
        guard let builder = builders[intent] else {
            throw ActionError.unknownAction(intent)
        }
        return try builder(parameters)
    }

    /// Sorted list of intent names. Surfaced in Settings → "What
    /// Sage can do" so users have a discoverable list of capabilities.
    var registeredIntents: [String] { builders.keys.sorted() }

    // MARK: - Private

    private func register(
        name: String,
        displayName: String,
        builder: @escaping Builder
    ) {
        builders[name] = builder
        displayNames[name] = displayName
    }
}
