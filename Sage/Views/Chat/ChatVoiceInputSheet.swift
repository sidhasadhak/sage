import SwiftUI

struct ChatVoiceInputSheet: View {
    let onTranscription: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var container: AppContainer

    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .idle
    @State private var pulseScale: CGFloat = 1.0

    enum Phase {
        case idle
        case recording
        case transcribing
        case done(String)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 28) {
            // Drag handle area
            Capsule()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 36, height: 5)
                .padding(.top, 12)

            Text("Voice Input")
                .font(Theme.headlineFont)

            Spacer()

            // Central area
            switch phase {
            case .idle, .recording:
                micSection

            case .transcribing:
                VStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.pulse)
                    Text("Transcribing…")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                }

            case .done(let text):
                VStack(alignment: .leading, spacing: 12) {
                    Text(text)
                        .font(Theme.bodyFont)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

                    HStack(spacing: 10) {
                        Button("Redo") { phase = .idle }
                            .buttonStyle(SageButtonStyle(filled: false))
                            .frame(maxWidth: .infinity)
                        Button("Use Text") {
                            onTranscription(text)
                            dismiss()
                        }
                        .buttonStyle(SageButtonStyle(filled: true))
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)

            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 36)).foregroundStyle(.red)
                    Text(msg).font(Theme.captionFont).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { phase = .idle }.buttonStyle(SageButtonStyle())
                }
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .onDisappear { recorder.cancelRecording() }
    }

    private var micSection: some View {
        VStack(spacing: 20) {
            ZStack {
                if phase.isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulseScale)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseScale)
                        .onAppear { pulseScale = 1.2 }
                        .onDisappear { pulseScale = 1.0 }
                }
                Button {
                    if phase.isRecording {
                        Task { await stopRecording() }
                    } else {
                        Task { await startRecording() }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(phase.isRecording ? Color.red : Color.accentColor)
                            .frame(width: 80, height: 80)
                        Image(systemName: phase.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    }
                }
            }

            VStack(spacing: 4) {
                Text(phase.isRecording ? recorder.durationString : "Tap to speak")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                Text(phase.isRecording ? "Tap to finish" : "Transcription will appear in the chat input")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func startRecording() async {
        guard await container.permissions.requestVoiceNotePermissionsIfNeeded() else {
            phase = .error("Microphone access is required. Enable it in Settings.")
            return
        }
        do {
            try recorder.startRecording()
            phase = .recording
        } catch {
            phase = .error("Could not start recording.")
        }
    }

    private func stopRecording() async {
        guard let url = recorder.stopRecording() else {
            phase = .error("No audio recorded.")
            return
        }
        phase = .transcribing
        // sage-slim: auto-send. The old flow (.done → "Use Text" button →
        // text pasted into input → user taps Send) is gone. Stop tap →
        // transcribe → fire onTranscription → dismiss. Three taps become
        // one. If transcription is wrong the user sees it land in the
        // chat as a user message and can edit / re-record.
        guard let text = try? await TranscriptionService.shared.transcribe(fileURL: url),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .error("Couldn't transcribe — please try again.")
            return
        }
        onTranscription(text)
        dismiss()
    }
}

private extension ChatVoiceInputSheet.Phase {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

private extension PermissionCoordinator {
    func requestVoiceNotePermissionsIfNeeded() async -> Bool {
        if !isMicrophoneAuthorized || !isSpeechAuthorized {
            await requestVoiceNotePermissions()
        }
        return isMicrophoneAuthorized && isSpeechAuthorized
    }
}
