import SwiftUI

// MARK: - UndoBar
//
// Phase 3: closes the loop in the chat UI after a verified action
// commits. Sits above the input bar for 8 seconds with one-tap Undo.
// Mirrors the iOS Mail "Undo Send" pattern — well-understood, low
// friction, and crucially honest: it tells the user exactly what
// happened ("Added X to Calendar — verified") so they can decide
// whether to keep it.

struct UndoBar: View {
    let receipt: PEVController.Receipt
    let onUndo:    () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: receipt.hasWarning
                  ? "exclamationmark.triangle.fill"
                  : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(receipt.hasWarning ? .orange : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.actionReceipt.summary)
                    .font(.system(.subheadline, weight: .medium))
                    .lineLimit(1)
                if receipt.verification.status == .passed {
                    Text("Verified")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !receipt.verification.detail.isEmpty {
                    Text(receipt.verification.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Undo", action: onUndo)
                .font(.system(.subheadline, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

#Preview("Verified") {
    UndoBar(
        receipt: .init(
            action: AnyAction.previewStub(),
            actionReceipt: .init(
                actionName: "create_event",
                entityID: "abc",
                summary: "Added \"Lunch with Alex\" to Calendar",
                rollbackSupported: true
            ),
            verification: .passed,
            summary: "✓ Added \"Lunch with Alex\" to Calendar — verified."
        ),
        onUndo: {}, onDismiss: {}
    )
}

#if DEBUG
extension AnyAction {
    static func previewStub() -> AnyAction {
        struct Stub: Action {
            static let name = "stub"
            static let displayName = "Stub"
            func dryRun() async throws -> ActionDiff {
                ActionDiff(summary: "x", icon: "circle", tint: .blue, confirmLabel: "OK", warnings: [])
            }
            func execute() async throws -> ActionReceipt {
                ActionReceipt(actionName: Self.name, entityID: nil, summary: "x", rollbackSupported: false)
            }
            func rollback(_ receipt: ActionReceipt) async throws {}
        }
        return AnyAction(Stub())
    }
}
#endif
