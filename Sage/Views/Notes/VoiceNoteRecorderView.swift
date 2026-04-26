import SwiftUI

/// Voice capture surface that records audio, transcribes it, asks the LLM
/// what the user actually wants, and shows a confirmation preview before
/// committing the action (note / checklist / reminder / event / chat).
struct VoiceNoteRecorderView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var container: AppContainer
    var viewModel: NotesViewModel?

    @State private var recorder = AudioRecorder()
    @State private var state: RecorderState = .idle
    @State private var recordedURL: URL?
    @State private var errorMessage: String?

    // Editable preview state — bound to text fields so the user can tweak
    // anything Sage misclassified before committing.
    @State private var editableTitle: String = ""
    @State private var editableItems: [String] = []
    @State private var editableDate: Date = Date()
    @State private var hasDate: Bool = false

    enum RecorderState: Equatable {
        case idle
        case recording
        case transcribing
        case analyzing
        case preview(VoiceIntent)
        case saving
        case done(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .preview(let intent):
                    previewScreen(intent)
                default:
                    captureScreen
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
    }

    private var navTitle: String {
        switch state {
        case .preview(let intent): return intent.kind.displayName
        case .done:                return "Done"
        default:                    return "Voice"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
                recorder.cancelRecording()
                dismiss()
            }
        }
    }

    // MARK: - Capture screen (idle / recording / transcribing / analyzing / saving / done)

    private var captureScreen: some View {
        VStack(spacing: 36) {
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

            Image(systemName: iconForState)
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: isProcessing)
        }
    }

    private var iconForState: String {
        switch state {
        case .recording:                 return "waveform"
        case .transcribing, .analyzing:  return "sparkles"
        case .saving:                    return "arrow.down.circle"
        case .done:                      return "checkmark.circle.fill"
        default:                          return "mic.fill"
        }
    }

    private var isProcessing: Bool {
        switch state {
        case .transcribing, .analyzing, .saving: return true
        default:                                  return false
        }
    }

    private var statusText: some View {
        VStack(spacing: 8) {
            switch state {
            case .idle:
                Text("Tap to record")
                    .font(Theme.titleFont)
                    .foregroundStyle(.secondary)
                Text("Speak naturally — Sage will figure out what to do.")
                    .font(Theme.captionFont)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            case .recording:
                Text(recorder.durationString)
                    .font(.system(.largeTitle, design: .monospaced, weight: .light))
                    .foregroundStyle(.primary)
                Text("Recording…")
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
            case .transcribing:
                Text("Transcribing…")
                    .font(Theme.titleFont)
                    .foregroundStyle(.secondary)
                ProgressView()
            case .analyzing:
                Text("Understanding…")
                    .font(Theme.titleFont)
                    .foregroundStyle(.secondary)
                Text("Sage is figuring out what you want.")
                    .font(Theme.captionFont)
                    .foregroundStyle(.tertiary)
                ProgressView()
            case .saving:
                Text("Saving…")
                    .font(Theme.titleFont)
                    .foregroundStyle(.secondary)
                ProgressView()
            case .done(let message):
                Text(message)
                    .font(Theme.titleFont)
                    .foregroundStyle(.green)
            case .preview:
                EmptyView()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            if state == .recording {
                Button {
                    recorder.cancelRecording()
                    state = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
                Button {
                    stopAndProcess()
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

    // MARK: - Preview screen

    @ViewBuilder
    private func previewScreen(_ intent: VoiceIntent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCard(intent)

                titleField

                kindSpecificFields(intent.kind)

                transcriptionCard(intent.transcription)

                Spacer(minLength: 12)
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            previewActions(intent)
                .padding(16)
                .background(.ultraThinMaterial)
        }
    }

    private func summaryCard(_ intent: VoiceIntent) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(intent.kind.accent.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: intent.kind.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(intent.kind.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(intent.kind.displayName)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(intent.kind.accent)
                Text(intent.summary)
                    .font(Theme.bodyFont)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(intent.kind.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Title")
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
            TextField("Title", text: $editableTitle)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func kindSpecificFields(_ kind: VoiceIntent.Kind) -> some View {
        switch kind {
        case .checklist:
            checklistEditor
        case .reminder:
            dateField(label: "When", optional: true)
        case .calendarEvent:
            dateField(label: "Starts", optional: false)
        case .note, .chat:
            EmptyView()
        }
    }

    private var checklistEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Items")
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    editableItems.append("")
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
            }
            ForEach(editableItems.indices, id: \.self) { i in
                HStack {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                    TextField("Item", text: Binding(
                        get: { editableItems[safe: i] ?? "" },
                        set: { newVal in
                            if editableItems.indices.contains(i) {
                                editableItems[i] = newVal
                            }
                        }
                    ))
                    Button {
                        if editableItems.indices.contains(i) {
                            editableItems.remove(at: i)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            if editableItems.isEmpty {
                Text("No items detected. Tap Add to enter items manually.")
                    .font(Theme.captionFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func dateField(label: String, optional: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
            if optional {
                Toggle("Set a time", isOn: $hasDate)
                    .font(Theme.bodyFont)
            }
            if hasDate || !optional {
                DatePicker("", selection: $editableDate)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
        }
    }

    private func transcriptionCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcription")
                .font(Theme.captionFont)
                .foregroundStyle(.secondary)
            Text(text)
                .font(Theme.bodyFont)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func previewActions(_ intent: VoiceIntent) -> some View {
        VStack(spacing: 8) {
            Button {
                Task { await commit(intent) }
            } label: {
                Text(primaryActionLabel(for: intent.kind))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SageButtonStyle())

            Button {
                // Fallback: save as a plain note instead of the suggested intent.
                Task { await saveAsPlainNote(intent.transcription) }
            } label: {
                Text(intent.kind == .note ? "Discard" : "Save as Note Instead")
                    .frame(maxWidth: .infinity)
                    .font(Theme.bodyFont)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func primaryActionLabel(for kind: VoiceIntent.Kind) -> String {
        switch kind {
        case .note:           return "Save Note"
        case .checklist:      return "Create Checklist"
        case .reminder:       return "Create Reminder"
        case .calendarEvent:  return "Add to Calendar"
        case .chat:           return "Ask Sage"
        }
    }

    // MARK: - Recording flow

    private func startRecording() {
        do {
            try recorder.startRecording()
            state = .recording
            errorMessage = nil
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopAndProcess() {
        guard let url = recorder.stopRecording() else {
            state = .idle
            return
        }
        recordedURL = url
        state = .transcribing

        Task {
            do {
                let transcription = try await TranscriptionService.shared.transcribe(fileURL: url)
                let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "Couldn't hear anything. Try again?"
                    state = .idle
                    return
                }

                state = .analyzing
                let intent = await container.llmService.analyzeVoiceIntent(transcription: trimmed)
                hydrateEditableFields(from: intent)
                state = .preview(intent)
            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
                state = .idle
            }
        }
    }

    private func hydrateEditableFields(from intent: VoiceIntent) {
        editableTitle = intent.title
        switch intent.kind {
        case .checklist(let items):
            editableItems = items
            hasDate = false
        case .reminder(let date):
            editableItems = []
            if let date {
                editableDate = date
                hasDate = true
            } else {
                editableDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
                hasDate = false
            }
        case .calendarEvent(let date):
            editableItems = []
            editableDate = date ?? (Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date())
            hasDate = true
        case .note, .chat:
            editableItems = []
            hasDate = false
        }
    }

    // MARK: - Commit

    private func commit(_ intent: VoiceIntent) async {
        state = .saving

        let title = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? intent.title
            : editableTitle

        switch intent.kind {
        case .note:
            await saveAsPlainNote(intent.transcription, customTitle: title)

        case .checklist:
            let items = editableItems
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { ChecklistItem(text: $0, isDone: false) }
            viewModel?.createChecklist(title: title, items: items)
            await finish(message: "Checklist created!")

        case .reminder:
            let due = hasDate ? editableDate : nil
            do {
                try await container.reminderService.createReminder(
                    title: title,
                    notes: intent.transcription,
                    dueDate: due
                )
                await finish(message: "Reminder created!")
            } catch {
                errorMessage = "Couldn't create reminder: \(error.localizedDescription)"
                await saveAsPlainNote(intent.transcription, customTitle: title)
            }

        case .calendarEvent:
            do {
                try await container.calendarEventService.createEvent(
                    title: title,
                    startDate: editableDate,
                    notes: intent.transcription
                )
                await finish(message: "Event added to calendar!")
            } catch {
                errorMessage = "Couldn't add event: \(error.localizedDescription)"
                await saveAsPlainNote(intent.transcription, customTitle: title)
            }

        case .chat:
            container.pendingVoiceChatQuery = intent.transcription
            await finish(message: "Opening Sage…")
        }
    }

    private func saveAsPlainNote(_ transcription: String, customTitle: String? = nil) async {
        state = .saving
        guard let viewModel else {
            await finish(message: "Saved!")
            return
        }
        // Reuse the already-computed transcription; don't re-run STT.
        _ = viewModel.createVoiceNote(
            audioURL: recordedURL,
            transcription: transcription,
            title: customTitle
        )
        await finish(message: "Note saved!")
    }

    private func finish(message: String) async {
        state = .done(message)
        try? await Task.sleep(for: .milliseconds(800))
        dismiss()
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
