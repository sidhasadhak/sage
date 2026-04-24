import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    let isGenerating: Bool
    var isFocused: FocusState<Bool>.Binding
    var onVoiceInput: (() -> Void)? = nil
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Mic button
            if let onVoiceInput {
                Button(action: onVoiceInput) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                }
            }

            TextField("Message Sage…", text: $text, axis: .vertical)
                .font(Theme.bodyFont)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .focused(isFocused)
                .onSubmit(of: .text) {
                    if !isGenerating { onSend() }
                }

            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(!canSend)
        .animation(Theme.easeAnimation, value: canSend)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating
    }
}
