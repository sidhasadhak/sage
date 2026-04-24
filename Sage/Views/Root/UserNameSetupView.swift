import SwiftUI

struct UserNameSetupView: View {
    @Binding var userName: String
    @Environment(\.dismiss) private var dismiss

    @State private var nameInput: String = ""
    @State private var suggestion: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 8) {
                    Text("Welcome to Sage")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("What should I call you?")
                        .font(Theme.bodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("Your name", text: $nameInput)
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                        .autocorrectionDisabled()
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit { saveAndDismiss() }

                    if !suggestion.isEmpty && nameInput.isEmpty {
                        Button {
                            nameInput = suggestion
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.fill")
                                    .font(.caption)
                                Text("Use \"\(suggestion)\"")
                                    .font(Theme.captionFont)
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                Button(action: saveAndDismiss) {
                    Text(nameInput.trimmingCharacters(in: .whitespaces).isEmpty ? "Skip for now" : "Get Started")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(SageButtonStyle(filled: !nameInput.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
        .interactiveDismissDisabled()
        .onAppear {
            suggestion = fetchNameSuggestion()
            fieldFocused = true
        }
    }

    private func saveAndDismiss() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        userName = trimmed
        dismiss()
    }

    private func fetchNameSuggestion() -> String {
        // Parse device name: "Amit's iPhone" → "Amit"
        let deviceName = UIDevice.current.name
        if let range = deviceName.range(of: "'s ", options: .caseInsensitive) {
            let name = String(deviceName[deviceName.startIndex..<range.lowerBound])
            if !name.isEmpty { return name }
        }
        for suffix in [" iPhone", " iPad", " iPod Touch"] {
            if deviceName.lowercased().hasSuffix(suffix.lowercased()) {
                let name = String(deviceName.dropLast(suffix.count))
                if !name.isEmpty { return name }
            }
        }
        return ""
    }
}
