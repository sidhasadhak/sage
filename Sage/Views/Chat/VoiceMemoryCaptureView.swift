import SwiftUI
import SwiftData

struct VoiceMemoryCaptureView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Optional: when set, a "chat" intent will call this instead of dismissing silently.
    var onChatIntent: ((String) -> Void)? = nil

    @State private var recorder = AudioRecorder()
    @State private var captureState: CaptureState = .idle
    @State private var pulseScale: CGFloat = 1.0

    enum CaptureState {
        case idle
        case recording
        case transcribing
        case understanding
        case preview(VoiceIntent, audioURL: URL)
        case executing
        case success(String)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Spacer()
            centralContent
            Spacer()
            bottomControls
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { recorder.cancelRecording() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Skip") { dismiss() }
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Voice Memory")
                .font(Theme.headlineFont)
            Spacer()
            Button("Skip") { }
                .font(Theme.captionFont)
                .hidden()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Central content router

    @ViewBuilder
    private var centralContent: some View {
        switch captureState {
        case .idle, .recording:
            recordingSection

        case .transcribing:
            processingSection(icon: "waveform", label: "Transcribing…")

        case .understanding:
            processingSection(icon: "brain.head.profile", label: "Understanding…")

        case .preview(let intent, _):
            intentPreviewSection(intent: intent)

        case .executing:
            processingSection(icon: "checkmark.circle", label: "Saving…")

        case .success(let msg):
            successSection(message: msg)

        case .error(let msg):
            errorSection(message: msg)
        }
    }

    // MARK: - Recording

    private var recordingSection: some View {
        VStack(spacing: 32) {
            ZStack {
                if case .recording = captureState {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 140, height: 140)
                        .scaleEffect(pulseScale)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseScale)
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
                Text(captureState.isRecording
                     ? "Tap to stop"
                     : "Speak a thought, list, reminder, or question")
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Processing

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

    // MARK: - Intent Preview

    private func intentPreviewSection(intent: VoiceIntent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Action badge
                HStack(spacing: 10) {
                    Image(systemName: intent.action.displayIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(actionColor(for: intent.action))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(intent.action.displayTitle)
                            .font(Theme.headlineFont)
                        if !intent.summary.isEmpty {
                            Text(intent.summary)
                                .font(Theme.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // Action-specific content preview
                actionPreviewContent(for: intent)

                // Labels
                if !intent.labels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Labels", systemImage: "tag.fill")
                            .font(Theme.captionFont)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(intent.labels, id: \.self) { label in
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
    }

    @ViewBuilder
    private func actionPreviewContent(for intent: VoiceIntent) -> some View {
        switch intent.action {
        case .saveNote(let title, let body):
            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty {
                    Text(title).font(Theme.headlineFont)
                }
                Text(body)
                    .font(Theme.bodyFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .createList(let title, let items):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.headlineFont)
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "square")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Text(item).font(Theme.bodyFont)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .createReminder(let title, let dueDate, let notes):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.headlineFont)
                if let due = dueDate {
                    Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(Theme.captionFont)
                        .foregroundStyle(.orange)
                }
                if let n = notes, !n.isEmpty {
                    Text(n).font(Theme.captionFont).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .createCalendarEvent(let title, let startDate, let location):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.headlineFont)
                if let start = startDate {
                    Label(start.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(Theme.captionFont)
                        .foregroundStyle(.indigo)
                }
                if let loc = location, !loc.isEmpty {
                    Label(loc, systemImage: "location.fill")
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .chat(let question):
            Text(question)
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }

    // MARK: - Success / Error

    private func successSection(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(message)
                .font(.system(.title3, design: .rounded, weight: .semibold))
        }
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
        switch captureState {
        case .preview(let intent, let audioURL):
            VStack(spacing: 10) {
                Button(intent.action.confirmLabel) {
                    Task { await executeIntent(intent, audioURL: audioURL) }
                }
                .buttonStyle(SageButtonStyle(filled: true))
                .frame(maxWidth: .infinity)

                // Fallback: always let the user save as a plain note
                if case .chat = intent.action {
                    // No fallback needed — chat is already the action
                } else {
                    Button("Save as Note Instead") {
                        Task {
                            await saveNote(
                                title: "Voice Note",
                                body: intent.transcription,
                                audioURL: audioURL,
                                labels: intent.labels
                            )
                        }
                    }
                    .buttonStyle(SageButtonStyle(filled: false))
                    .frame(maxWidth: .infinity)
                }

                Button("Redo") { captureState = .idle }
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Recording flow

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

        captureState = .understanding
        let intent = await container.llmService.analyzeVoiceIntent(transcription: transcription)
        captureState = .preview(intent, audioURL: audioURL)
    }

    // MARK: - Intent execution

    private func executeIntent(_ intent: VoiceIntent, audioURL: URL) async {
        captureState = .executing
        do {
            switch intent.action {
            case .saveNote(let title, let body):
                await saveNote(title: title, body: body, audioURL: audioURL, labels: intent.labels)
                captureState = .success("Note saved")

            case .createList(let title, let items):
                let body = items.map { "- [ ] \($0)" }.joined(separator: "\n")
                await saveNote(title: title, body: body, audioURL: audioURL, labels: intent.labels, isChecklist: true)
                captureState = .success("\(title) created with \(items.count) items")

            case .createReminder(let title, let dueDate, let notes):
                try await container.reminderService.createReminder(title: title, notes: notes, dueDate: dueDate)
                captureState = .success("Reminder set: \(title)")

            case .createCalendarEvent(let title, let startDate, _):
                try await container.calendarEventService.createEvent(title: title, startDate: startDate)
                captureState = .success("Event added: \(title)")

            case .chat(let question):
                onChatIntent?(question)
                captureState = .success("Opening chat…")
            }

            try? await Task.sleep(for: .seconds(1.5))
            dismiss()
        } catch {
            captureState = .error(error.localizedDescription)
        }
    }

    // MARK: - Note persistence

    private func saveNote(
        title: String,
        body: String,
        audioURL: URL,
        labels: [String],
        isChecklist: Bool = false
    ) async {
        let note = Note(title: title, body: body, isVoiceNote: true)
        note.isChecklist = isChecklist
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        note.audioFileRelativePath = audioURL.path.replacingOccurrences(of: docsURL.path + "/", with: "")
        note.transcription = note.transcription ?? body
        modelContext.insert(note)
        try? modelContext.save()
        await container.indexingService.indexNote(note, labels: labels.isEmpty ? nil : labels)
    }

    // MARK: - Helpers

    private func actionColor(for action: VoiceIntent.Action) -> Color {
        switch action {
        case .saveNote:            return .blue
        case .createList:          return .green
        case .createReminder:      return .orange
        case .createCalendarEvent: return .indigo
        case .chat:                return .accentColor
        }
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
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing; x = bounds.minX; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Permission helper

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
