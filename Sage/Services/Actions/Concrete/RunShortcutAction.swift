import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - RunShortcutAction
//
// Hands control off to the Shortcuts app via the public `shortcuts://`
// URL scheme. Parameters from the router:
//   • shortcut_name (required) — the user's Shortcut name, exactly
//                                 as it appears in the Shortcuts app.
//   • input         (optional) — text to pass as the shortcut's input.
//
// This is the most explicitly *uncomposable* action in Phase 1: once
// we hand off, the user is in the Shortcuts app and we can't observe
// the result. That's a feature, not a bug — Apple's URL scheme is the
// supported way to invoke user shortcuts, and pretending we have more
// control than we do would only create false confidence.
//
// Rollback: not supported. Sage cannot un-run a shortcut.

@MainActor
final class RunShortcutAction: Action {

    static let name        = "run_shortcut"
    static let displayName = "Run Shortcut"

    struct Parameters: Sendable, Equatable {
        let shortcutName: String
        let input: String?
    }

    let parameters: Parameters

    init(rawParameters: [String: String]) throws {
        self.parameters = Parameters(
            shortcutName: try ActionParam.string("shortcut_name", in: rawParameters),
            input:        ActionParam.optionalString("input", in: rawParameters)
        )
    }

    // MARK: - Action conformance

    func dryRun() async throws -> ActionDiff {
        let summary = parameters.input == nil
            ? "Run Shortcut \"\(parameters.shortcutName)\""
            : "Run Shortcut \"\(parameters.shortcutName)\" with input \"\(parameters.input!.prefix(40))\""

        var warnings = ["Sage hands off to the Shortcuts app and can't see the result."]

        #if canImport(UIKit)
        if let url = Self.makeURL(name: parameters.shortcutName, input: parameters.input),
           !UIApplication.shared.canOpenURL(url) {
            warnings.append("Shortcuts URL scheme isn't available on this device.")
        }
        #endif

        return ActionDiff(
            summary: summary,
            icon: "square.stack.3d.up.fill",
            tint: .purple,
            confirmLabel: "Run Shortcut",
            warnings: warnings
        )
    }

    func execute() async throws -> ActionReceipt {
        guard let url = Self.makeURL(name: parameters.shortcutName, input: parameters.input) else {
            throw ActionError.invalidParameter(name: "shortcut_name", reason: "couldn't build a valid URL")
        }
        #if canImport(UIKit)
        let opened = await UIApplication.shared.open(url)
        if !opened {
            throw ActionError.permissionDenied("Could not open Shortcuts. Make sure the Shortcut name is correct.")
        }
        #endif
        return ActionReceipt(
            actionName: Self.name,
            entityID: nil,
            summary: "Ran Shortcut \"\(parameters.shortcutName)\"",
            rollbackSupported: false
        )
    }

    func rollback(_ receipt: ActionReceipt) async throws {
        throw ActionError.rollbackUnsupported(Self.name)
    }

    // MARK: - Helpers

    static func makeURL(name: String, input: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host   = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let input { items.append(URLQueryItem(name: "input", value: input)) }
        components.queryItems = items
        return components.url
    }
}
