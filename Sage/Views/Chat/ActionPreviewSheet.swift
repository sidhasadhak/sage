import SwiftUI

// MARK: - ActionPreviewSheet
//
// Bottom-sheet diff for a Phase-1 action. The user MUST see this and
// tap Approve before any side effect happens — this is the "hard
// rail" half of the v1.2 plan #2 (deterministic action layer with
// safety rails). Cancel is always one tap away.
//
// Layout:
//   ┌────────────────────────────────┐
//   │  ⓘ icon   Display name          │   header (tinted)
//   │  Summary line wrapping 2 lines  │
//   │                                 │
//   │  ⚠︎ warning 1                   │   warnings (gray pills)
//   │  ⚠︎ warning 2                   │
//   │                                 │
//   │  [Cancel]  [Confirm Label]      │   actions
//   └────────────────────────────────┘

struct ActionPreviewSheet: View {
    let diff: ActionDiff
    let displayName: String
    let isExecuting: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Text(diff.summary)
                .font(.system(.body, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)

            if !diff.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(diff.warnings, id: \.self) { warning in
                        Label {
                            Text(warning).font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            actionButtons
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isExecuting)   // can't swipe-away mid-execute
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tintColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: diff.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tintColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(.headline, design: .rounded))
                Text("Review and approve")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
                    .font(.system(.subheadline, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isExecuting)
            .buttonStyle(.plain)

            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    if isExecuting {
                        ProgressView().tint(.white)
                    }
                    Text(isExecuting ? "Working…" : diff.confirmLabel)
                        .font(.system(.subheadline, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(tintColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isExecuting)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Tint mapping

    private var tintColor: Color {
        switch diff.tint {
        case .orange: return .orange
        case .blue:   return .blue
        case .red:    return .red
        case .green:  return .green
        case .purple: return .purple
        case .gray:   return .gray
        }
    }
}

// MARK: - Preview

#Preview("With warnings") {
    ActionPreviewSheet(
        diff: ActionDiff(
            summary: "Create reminder \"Call dentist\" — due tomorrow at 9:00 AM",
            icon: "bell.fill",
            tint: .orange,
            confirmLabel: "Create Reminder",
            warnings: ["Reminders access required. Sage will ask the first time."]
        ),
        displayName: "Create Reminder",
        isExecuting: false,
        onConfirm: {},
        onCancel: {}
    )
}

#Preview("Executing") {
    ActionPreviewSheet(
        diff: ActionDiff(
            summary: "Add \"Lunch with Alex\" to Calendar — Apr 30, 12:30 PM (60 min)",
            icon: "calendar.badge.plus",
            tint: .blue,
            confirmLabel: "Add to Calendar",
            warnings: []
        ),
        displayName: "Add to Calendar",
        isExecuting: true,
        onConfirm: {},
        onCancel: {}
    )
}
