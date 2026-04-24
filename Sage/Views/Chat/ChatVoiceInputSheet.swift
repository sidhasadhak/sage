import SwiftUI
import SwiftData

struct ChatVoiceInputSheet: View {
    /// Called when the user wants to send text to the chat input field.
    let onTranscription: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) var modelContext
    @EnvironmentObject var container: AppContainer

    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .idle
    @State private var pulseScale: CGFloat = 1.0

    enum Phase {
        case idle
        case recording
        case transcribing
        case analyzing
        case preview(VoiceIntent)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 28) {
            Capsule()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 36, height: 5)
                .padding(.top, 12)

            Text("Voice Input")
                .font(Theme.headlineFont)

            Spacer()

            switch phase {
            case .idle, .recording:
                micSection

            case .transcribing:
                processingView(icon: "waveform", label: "Transcribing…")

            case .analyzing:
                processingView(icon: "brain.head.profile", label: "Understanding…")

            case .preview(let intent):
                intentPreview(intent: intent)

            case .error(let msg):
                errorView(message: msg)
            }

            Spacer()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .onDisappear { recorder.cancelRecording() }
    }

    // MARK: - Mic

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
                    if phase.isRecording { Task { await stopRecording() } }
                    else { Task { await startRecording() } }
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
                Text(phase.isRecording ? "Tap to finish" : "Sage will understand your intent")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Intent preview

    private func intentPreview(intent: VoiceIntent) -> some View {
        VStack(spacing: 16) {
            // Action badge
            HStack(spacing: 10) {
                Image(systemName: intent.action.displayIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(actionColor(for: intent.action))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(intent.action.displayTitle)
                        .font(Theme.headlineFont)
                    if !intent.summary.isEmpty {
                        Text(intent.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)

            // Content preview
            actionContentPreview(for: intent)
                .padding(.horizontal, 24)

            // Buttons
            VStack(spacing: 10) {
                // Primary: execute the action (if not chat) or send to chat (if chat)
                if case .chat(let q) = intent.action {
                    Button("Send to Chat") {
                        onTranscription(q)
                        dismiss()
                    }
                    .buttonStyle(SageButtonStyle(filled: true))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                } else {
                    Button(intent.action.confirmLabel) {
                        Task { await executeAction(intent) }
                    }
                    .buttonStyle(SageButtonStyle(filled: true))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)

                    // Secondary: always let user send transcription to chat
                    Button("Send to Chat Instead") {
                        onTranscription(intent.transcription)
                        dismiss()
                    }
                    .buttonStyle(SageButtonStyle(filled: false))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                }

                Button("Redo") { phase = .idle }
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionContentPreview(for intent: VoiceIntent) -> some View {
        switch intent.action {
        case .saveNote(_, let body):
            Text(body)
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .createList(_, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.prefix(5), id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "square").font(.caption).foregroundStyle(.secondary)
                        Text(item).font(Theme.bodyFont)
                    }
                }
                if items.count > 5 {
                    Text("+ \(items.count - 5) more…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .createReminder(let title, let dueDate, _):
            HStack(spacing: 8) {
                Image(systemName: "bell.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.bodyFont)
                    if let due = dueDate {
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .createCalendarEvent(let title, let startDate, let location):
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.bodyFont)
                if let s = startDate {
                    Label(s.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.caption).foregroundStyle(.indigo)
                }
                if let loc = location, !loc.isEmpty {
                    Label(loc, systemImage: "location.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))

        case .chat(let question):
            Text(question)
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
    }

    // MARK: - Processing / Error

    private func processingView(icon: String, label: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 36)).foregroundStyle(.red)
            Text(message)
                .font(Theme.captionFont).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { phase = .idle }
                .buttonStyle(SageButtonStyle())
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Recording flow

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
        guard let text = try? await TranscriptionService.shared.transcribe(fileURL: url),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .error("Couldn't transcribe — please try again.")
            return
        }
        phase = .analyzing
        let intent = await container.llmService.analyzeVoiceIntent(transcription: text)
        phase = .preview(intent)
    }

    // MARK: - Action execution

    private func executeAction(_ intent: VoiceIntent) async {
        do {
            switch intent.action {
            case .saveNote(let title, let body):
                let note = Note(title: title, body: body, isVoiceNote: true)
                note.transcription = body
                modelContext.insert(note)
                try? modelContext.save()
                await container.indexingService.indexNote(note, labels: intent.labels.isEmpty ? nil : intent.labels)

            case .createList(let title, let items):
                let body = items.map { "- [ ] \($0)" }.joined(separator: "\n")
                let note = Note(title: title, body: body, isVoiceNote: true)
                note.isChecklist = true
                modelContext.insert(note)
                try? modelContext.save()
                await container.indexingService.indexNote(note, labels: intent.labels.isEmpty ? nil : intent.labels)

            case .createReminder(let title, let dueDate, let notes):
                try await container.reminderService.createReminder(title: title, notes: notes, dueDate: dueDate)

            case .createCalendarEvent(let title, let startDate, _):
                try await container.calendarEventService.createEvent(title: title, startDate: startDate)

            case .chat(let q):
                onTranscription(q)
            }
            dismiss()
        } catch {
            phase = .error(error.localizedDescription)
        }
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
