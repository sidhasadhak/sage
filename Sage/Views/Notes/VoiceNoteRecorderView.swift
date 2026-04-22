import SwiftUI

struct VoiceNoteRecorderView: View {
    @Environment(\.dismiss) var dismiss
    var viewModel: NotesViewModel?

    @State private var recorder = AudioRecorder()
    @State private var state: RecorderState = .idle
    @State private var recordedURL: URL?
    @State private var errorMessage: String?

    enum RecorderState {
        case idle, recording, processing, done
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 40) {
                Spacer()

                waveformAnimation

                statusText

                controls

                Spacer()

                if let error = errorMessage {
                    Text(error)
                        .font(Theme.captionFont)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .navigationTitle("Voice Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        recorder.cancelRecording()
                        dismiss()
                    }
                }
            }
        }
    }

    private var waveformAnimation: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.1))
                .frame(width: 160, height: 160)
                .scaleEffect(state == .recording ? 1.15 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                           value: state == .recording)

            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 120, height: 120)

            Image(systemName: state == .recording ? "waveform" : "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: state == .recording)
        }
    }

    private var statusText: some View {
        VStack(spacing: 8) {
            switch state {
            case .idle:
                Text("Tap to record")
                    .font(Theme.titleFont)
                    .foregroundStyle(.secondary)
            case .recording:
                Text(recorder.durationString)
                    .font(.system(.largeTitle, design: .monospaced, weight: .light))
                    .foregroundStyle(.primary)
                Text("Recording…")
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
            case .processing:
                Text("Transcribing…")
                    .font(Theme.titleFont)
                    .foregroundStyle(.secondary)
                ProgressView()
            case .done:
                Text("Note saved!")
                    .font(Theme.titleFont)
                    .foregroundStyle(.green)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            if state == .recording {
                // Cancel recording
                Button {
                    recorder.cancelRecording()
                    state = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }

                // Stop and save
                Button {
                    stopAndSave()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.accentColor)
                }
            } else if state == .idle {
                Button {
                    startRecording()
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: 72))
                        .foregroundStyle(.red)
                }
            }
        }
        .animation(Theme.easeAnimation, value: state)
    }

    private func startRecording() {
        do {
            try recorder.startRecording()
            state = .recording
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopAndSave() {
        guard let url = recorder.stopRecording() else {
            state = .idle
            return
        }
        recordedURL = url
        state = .processing

        Task {
            _ = await viewModel?.createVoiceNote(audioURL: url)
            state = .done
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}
