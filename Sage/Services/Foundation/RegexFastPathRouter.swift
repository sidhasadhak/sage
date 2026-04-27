import Foundation

// MARK: - RegexFastPathRouter
//
// Pragmatic reliability layer. The Phase-0 plan called for the
// `parseIntent` regex to die — and it has, as the *only* path. But on
// devices without Apple Intelligence the router falls back to Llama
// 3.2 3B with strict-JSON prompting, and small models miss obvious
// triggers like "remind me to call mom". The user-visible result was
// that action phrases silently fell through to chat with no preview
// sheet and no Undo bar.
//
// This wrapper restores deterministic routing for ~90% of action
// phrases (the trigger patterns are well-tested) without ceding the
// open-ended cases. The inner router still owns everything that
// doesn't match a fast-path pattern.

struct RegexFastPathRouter: IntentRouter {

    /// Used in Diagnostics so we can tell at a glance which backend
    /// is doing the heavy lifting.
    let implementationName: String

    private let inner: any IntentRouter

    init(wrapping inner: any IntentRouter) {
        self.inner = inner
        self.implementationName = "RegexFastPath → \(inner.implementationName)"
    }

    func classify(_ userInput: String, history: [String]) async throws -> RouterDecision {
        if let decision = Self.matchFastPath(userInput) {
            return decision
        }
        return try await inner.classify(userInput, history: history)
    }

    // MARK: - Fast-path matching
    //
    // Pure function so it's trivially testable. Runs in well under a
    // millisecond even on the slowest device — strictly cheaper than
    // a model call.

    static func matchFastPath(_ input: String) -> RouterDecision? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // Date detection runs once and is shared across both branches.
        let detectedDate: Date? = {
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            return detector.matches(in: trimmed, options: [], range: range).first?.date
        }()

        // ── Reminders ──────────────────────────────────────────────
        for trigger in reminderTriggers where lower.contains(trigger) {
            let title = extractTitle(from: trimmed, after: trigger) ?? trimmed
            var params: [String: String] = ["title": String(title.prefix(120))]
            if let d = detectedDate {
                params["due_date"] = isoString(d)
            }
            return .action(ActionPlan(
                intent: "create_reminder",
                parameters: params,
                confidence: 0.9
            ))
        }

        // ── Calendar events ────────────────────────────────────────
        for trigger in eventTriggers where lower.contains(trigger) {
            let title = extractTitle(from: trimmed, after: trigger) ?? trimmed
            var params: [String: String] = ["title": String(title.prefix(120))]
            if let d = detectedDate {
                params["start_date"] = isoString(d)
            }
            return .action(ActionPlan(
                intent: "create_event",
                parameters: params,
                confidence: 0.9
            ))
        }

        // ── Shortcut runs ──────────────────────────────────────────
        // "run my <name> shortcut" / "run shortcut <name>".
        if let match = matchRunShortcut(in: trimmed) {
            return .action(ActionPlan(
                intent: "run_shortcut",
                parameters: ["shortcut_name": match],
                confidence: 0.85
            ))
        }

        return nil
    }

    // MARK: - Trigger packs

    private static let reminderTriggers: [String] = [
        "remind me to", "remind me about", "reminder to",
        "don't forget to", "remember to", "add reminder",
        "set reminder", "set a reminder", "set a reminder to"
    ]

    private static let eventTriggers: [String] = [
        "schedule a meeting", "set up a meeting", "book a meeting",
        "create an event", "add to calendar", "schedule meeting",
        "book appointment", "create appointment", "set a meeting",
        "schedule an event", "plan a meeting", "arrange a meeting",
        "set up a call", "book a call"
    ]

    // MARK: - Helpers

    /// Returns the substring after `pattern` (case-insensitive),
    /// trimmed. nil when the pattern isn't present or the suffix is
    /// empty whitespace.
    static func extractTitle(from text: String, after pattern: String) -> String? {
        guard let range = text.lowercased().range(of: pattern) else { return nil }
        let after = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return after.isEmpty ? nil : after
    }

    /// "run my Goodnight shortcut" → "Goodnight"
    /// "run shortcut Goodnight"     → "Goodnight"
    static func matchRunShortcut(in text: String) -> String? {
        let lower = text.lowercased()
        let patterns = [
            #"run\s+my\s+(.+?)\s+shortcut"#,
            #"run\s+the\s+(.+?)\s+shortcut"#,
            #"run\s+shortcut\s+(.+)$"#
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let range = NSRange(lower.startIndex..., in: lower)
            guard let match = regex.firstMatch(in: lower, range: range), match.numberOfRanges >= 2 else { continue }
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// ISO-8601 with fractional seconds — matches the format
    /// `ActionParam.parseDate` decodes first.
    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
