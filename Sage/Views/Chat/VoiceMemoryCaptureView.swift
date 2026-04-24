import SwiftUI
import SwiftData

struct VoiceMemoryCaptureView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = AudioRecorder()
    @State private var captureState: CaptureState = .idle
    @State private var pulseScale: CGFloat = 1.0

    enum CaptureState {
        case idle
        case recording
        case transcribing
        case labeling
        case done(transcription: String, labels: [String], audioURL: URL)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Skip") { dismiss() }
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Voice Memory")
                    .font(Theme.headlineFont)
                Spacer()
                // Balance the skip button width
                Button("Skip") {}
                    .font(Theme.captionFont)
                    .hidden()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Divider()

            Spacer()

            // Central content
            switch captureState {
            case .idle, .recording:
                recordingSection

            case .transcribing:
                processingSection(icon: "waveform", label: "Transcribing…")

            case .labeling:
                processingSection(icon: "tag.fill", label: "Generating labels…")

            case .done(let transcription, let labels, _):
                doneSection(transcription: transcription, labels: labels)

            case .error(let msg):
                errorSection(message: msg)
            }

            Spacer()

            // Bottom controls
            bottomControls
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { recorder.cancelRecording() }
    }

    // MARK: - Sections

    private var recordingSection: some View {
        VStack(spacing: 32) {
            // Mic button with pulse animation
            ZStack {
                if case .recording = captureState {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 140, height: 140)
                        .scaleEffect(pulseScale)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: pulseScale
                        )
                        .onAppear { pulseScale = 1.25 }
                        .onDisappear { pulseScale = 1.0 }
                }

                Button {
                    if case .recording = captureState {
                        Task { await stopRecording() }
                    } else {
                        Task { await startRecording() }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(captureState.isRecording ? Color.red : Color.accentColor)
                            .frame(width: 100, height: 100)
                        Image(systemName: captureState.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                    }
                }
            }

            VStack(spacing: 8) {
                Text(captureState.isRecording ? recorder.durationString : "Tap to record")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())

                Text(captureState.isRecording ? "Tap to stop" : "Speak your thought — it'll be saved as a memory")
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func processingSection(icon: String, label: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)
            Text(label)
                .font(.system(.title3, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func doneSection(transcription: String, labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Transcription
            VStack(alignment: .leading, spacing: 8) {
                Label("Transcription", systemImage: "text.quote")
                    .font(Theme.captionFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(transcription)
                    .font(Theme.bodyFont)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }

            // Labels
            if !labels.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Labels (\(labels.count))", systemImage: "tag.fill")
                        .font(Theme.captionFont)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(labels, id: \.self) { label in
                            Text(label)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func errorSection(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(message)
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") { captureState = .idle }
                .buttonStyle(SageButtonStyle())
        }
    }

    // MARK: - Bottom controls

    @ViewBuilder
    private var bottomControls: some View {
        if case .done(let transcription, let labels, let audioURL) = captureState {
            HStack(spacing: 12) {
                Button("Discard") {
                    captureState = .idle
                }
                .buttonStyle(SageButtonStyle(filled: false))
                .frame(maxWidth: .infinity)

                Button("Save Memory") {
                    Task { await saveMemory(transcription: transcription, labels: labels, audioURL: audioURL) }
                }
                .buttonStyle(SageButtonStyle(filled: true))
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func startRecording() async {
        guard await container.permissions.requestVoiceNotePermissionsIfNeeded() else {
            captureState = .error("Microphone or speech access is required. Enable it in Settings.")
            return
        }
        do {
            try recorder.startRecording()
            captureState = .recording
        } catch {
            captureState = .error("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecording() async {
        guard let audioURL = recorder.stopRecording() else {
            captureState = .error("Recording failed — no audio was saved.")
            return
        }

        captureState = .transcribing
        guard let transcription = try? await TranscriptionService.shared.transcribe(fileURL: audioURL),
              !transcription.trimmingCharacters(in: .whitespaces).isEmpty else {
            captureState = .error("Could not transcribe the recording. Please try again.")
            return
        }

        captureState = .labeling
        let labels = await container.llmService.generateLabels(for: transcription)

        captureState = .done(transcription: transcription, labels: labels, audioURL: audioURL)
    }

    private func saveMemory(transcription: String, labels: [String], audioURL: URL) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let title = "Voice Memory — \(dateFormatter.string(from: Date()))"

        let note = Note(title: title, body: transcription, isVoiceNote: true)
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        note.audioFileRelativePath = audioURL.path.replacingOccurrences(of: docsURL.path + "/", with: "")
        note.transcription = transcription
        modelContext.insert(note)
        try? modelContext.save()

        await container.indexingService.indexNote(note, labels: labels.isEmpty ? nil : labels)

        dismiss()
    }
}

// MARK: - Flow layout for labels

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > width && rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Permission helper extension

private extension PermissionCoordinator {
    func requestVoiceNotePermissionsIfNeeded() async -> Bool {
        if !isMicrophoneAuthorized || !isSpeechAuthorized {
            await requestVoiceNotePermissions()
        }
        return isMicrophoneAuthorized && isSpeechAuthorized
    }
}

private extension VoiceMemoryCaptureView.CaptureState {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
