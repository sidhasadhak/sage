import SwiftUI
import SwiftData

// MARK: - ChatListView (Unified Assistant Hub)
//
// The Chat tab is now the single entry point for all input:
//   • Text → analysed by LLM → note / checklist / reminder / event / chat
//   • Voice mic → VoiceNoteRecorderView (same LLM intent routing, full preview)
//   • Past conversations → tap to re-open
//
// Non-chat intents (note, checklist, reminder, calendar event) are executed
// directly and confirmed with a brief toast. No conversation is created.
// Chat intents open ChatView and create a conversation as before.

struct ChatListView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) var conversations: [Conversation]

    // Navigation
    @State private var selectedConversation: Conversation?
    @State private var showingChat = false

    // Text input & analysis
    @State private var inputText = ""
    @State private var isAnalyzing = false
    @FocusState private var inputFocused: Bool

    // Intent preview card (shown after LLM classifies non-chat input)
    @State private var pendingIntent: VoiceIntent?

    // Voice recorder (full VoiceNoteRecorderView flow)
    @State private var showVoiceRecorder = false
    @State private var notesViewModel: NotesViewModel?

    // Action toast
    @State private var toast: ActionToast?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Main content area
                Group {
                    if conversations.isEmpty {
                        emptyState
                    } else {
                        conversationList
                    }
                }

                // Layered bottom stack: toast → intent preview → input bar
                VStack(spacing: 0) {
                    if let t = toast {
                        toastBanner(t)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if let intent = pendingIntent {
                        intentPreviewCard(intent)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    inputBar
                        .background(.ultraThinMaterial)
                }
                .animation(.spring(duration: 0.3), value: toast?.id)
                .animation(.spring(duration: 0.3), value: pendingIntent != nil)
            }
            .navigationTitle("Sage")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showingChat) {
                ChatView(conversation: selectedConversation)
                    .environmentObject(container)
            }
            .sheet(isPresented: $showVoiceRecorder) {
                VoiceNoteRecorderView(viewModel: notesViewModel)
                    .environmentObject(container)
            }
            .onAppear {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await container.loadChatModelIfNeeded()
                }
                if container.pendingVoiceChatQuery != nil {
                    selectedConversation = nil
                    showingChat = true
                }
            }
            .task {
                notesViewModel = NotesViewModel(
                    modelContext: modelContext,
                    indexingService: container.indexingService,
                    permissions: container.permissions
                )
            }
            .onChange(of: container.pendingVoiceChatQuery) { _, query in
                guard query != nil else { return }
                selectedConversation = nil
                showingChat = true
            }
        }
    }

    // MARK: - Unified input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Multi-line text field
            TextField("Ask anything, jot a note, set a reminder…", text: $inputText, axis: .vertical)
                .font(.system(.body, design: .rounded))
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($inputFocused)
                .disabled(isAnalyzing)
                .onSubmit { submitInput() }

            // Voice button
            Button { showVoiceRecorder = true } label: {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
            }
            .accessibilityLabel("Voice input")

            // Send / analyzing indicator
            Button { submitInput() } label: {
                Circle()
                    .fill(sendButtonActive ? Color.accentColor : Color(.secondarySystemBackground))
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isAnalyzing {
                            ProgressView()
                                .tint(Color.accentColor)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(sendButtonActive ? .white : Color.secondary)
                        }
                    }
            }
            .disabled(!sendButtonActive || isAnalyzing)
            .accessibilityLabel(isAnalyzing ? "Analyzing" : "Send")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 20) // home-bar clearance
    }

    private var sendButtonActive: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Intent preview card

    private func intentPreviewCard(_ intent: VoiceIntent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header row: icon + title + summary + dismiss
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(intent.kind.accent.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: intent.kind.systemImage)
                        .font(.system(size: 18))
                        .foregroundStyle(intent.kind.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(intent.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                    Text(intent.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    withAnimation { pendingIntent = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }

            // Action buttons
            HStack(spacing: 10) {
                Button {
                    let captured = intent
                    withAnimation { pendingIntent = nil }
                    Task { await executeIntent(captured) }
                } label: {
                    Text(confirmLabel(for: intent.kind))
                        .font(.system(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(intent.kind.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    let text = intent.transcription
                    withAnimation { pendingIntent = nil }
                    openChat(with: text)
                } label: {
                    Text("Ask Sage instead")
                        .font(.system(.subheadline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color(.secondarySystemBackground))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Toast banner

    private func toastBanner(_ t: ActionToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: t.icon)
                .foregroundStyle(t.color)
                .font(.system(size: 15, weight: .semibold))
            Text(t.message)
                .font(.system(.subheadline, weight: .medium))
            Spacer()
            Button {
                withAnimation { toast = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(t.color.opacity(0.1))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Submit & route

    private func submitInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnalyzing else { return }
        inputText = ""
        inputFocused = false
        isAnalyzing = true
        pendingIntent = nil

        Task {
            let intent = await container.llmService.analyzeVoiceIntent(transcription: text)
            isAnalyzing = false
            if case .chat = intent.kind {
                openChat(with: text)
            } else {
                withAnimation(.spring(duration: 0.3)) {
                    pendingIntent = intent
                }
            }
        }
    }

    private func openChat(with text: String) {
        container.pendingVoiceChatQuery = text
        selectedConversation = nil
        showingChat = true
    }

    // MARK: - Execute non-chat intents

    @MainActor
    private func executeIntent(_ intent: VoiceIntent) async {
        let result = await performAction(for: intent)
        withAnimation(.spring(duration: 0.3)) {
            toast = result
        }
        // Auto-dismiss after 3 s
        try? await Task.sleep(for: .seconds(3))
        withAnimation { if toast?.id == result.id { toast = nil } }
    }

    @MainActor
    private func performAction(for intent: VoiceIntent) async -> ActionToast {
        let title = intent.title.isEmpty ? "Untitled" : intent.title

        switch intent.kind {
        case .chat:
            // Shouldn't reach here — caught in submitInput — but be safe.
            openChat(with: intent.transcription)
            return ActionToast(icon: "bubble.left.fill", message: "Opening chat…", color: .purple)

        case .note:
            let note = Note(title: title, body: intent.transcription)
            modelContext.insert(note)
            try? modelContext.save()
            Task { await container.indexingService.indexNote(note) }
            return ActionToast(icon: "doc.text.fill", message: "Note saved to Notes tab", color: Color(red: 0.95, green: 0.7, blue: 0.1))

        case .checklist(let items):
            let checklistItems = items
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { ChecklistItem(text: $0, isDone: false) }
            if let vm = notesViewModel {
                vm.createChecklist(title: title, items: checklistItems)
            } else {
                // Fallback if viewModel not yet ready
                let note = Note(title: title, body: items.joined(separator: "\n"))
                note.isChecklist = true
                note.checklistData = try? JSONEncoder().encode(checklistItems)
                modelContext.insert(note)
                try? modelContext.save()
            }
            return ActionToast(icon: "checklist", message: "Checklist saved to Notes tab", color: .blue)

        case .reminder(let dueDate):
            do {
                try await container.reminderService.createReminder(
                    title: title,
                    notes: intent.transcription,
                    dueDate: dueDate
                )
                return ActionToast(icon: "bell.fill", message: "Reminder set", color: .orange)
            } catch {
                // Graceful fallback: save as note
                let note = Note(title: title, body: intent.transcription)
                modelContext.insert(note)
                try? modelContext.save()
                Task { await container.indexingService.indexNote(note) }
                return ActionToast(icon: "exclamationmark.triangle.fill",
                                   message: "Saved as note (Reminders access needed)",
                                   color: .red)
            }

        case .calendarEvent(let startDate):
            do {
                try await container.calendarEventService.createEvent(
                    title: title,
                    startDate: startDate,
                    notes: intent.transcription
                )
                return ActionToast(icon: "calendar.badge.plus", message: "Event added to Calendar", color: .red)
            } catch {
                let note = Note(title: title, body: intent.transcription)
                modelContext.insert(note)
                try? modelContext.save()
                Task { await container.indexingService.indexNote(note) }
                return ActionToast(icon: "exclamationmark.triangle.fill",
                                   message: "Saved as note (Calendar access needed)",
                                   color: .red)
            }
        }
    }

    // MARK: - Helpers

    private func confirmLabel(for kind: VoiceIntent.Kind) -> String {
        switch kind {
        case .note:          return "Save Note"
        case .checklist:     return "Create Checklist"
        case .reminder:      return "Set Reminder"
        case .calendarEvent: return "Add to Calendar"
        case .chat:          return "Ask Sage"
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.08))
                        .frame(width: 100, height: 100)
                    Circle()
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 74, height: 74)
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 8) {
                    Text("Ask Sage anything")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Type or speak — Sage understands questions,\nnotes, reminders, and calendar events.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Pill hints
                HStack(spacing: 8) {
                    ForEach(["💬 Chat", "📝 Notes", "🔔 Reminders", "📅 Events"], id: \.self) { hint in
                        Text(hint)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            // Spacer so content isn't hidden behind input bar
            Color.clear.frame(height: 130)
        }
    }

    // MARK: - Conversation list

    private var conversationList: some View {
        List {
            ForEach(conversations) { conversation in
                Button {
                    selectedConversation = conversation
                    showingChat = true
                } label: {
                    ConversationRow(conversation: conversation)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .onDelete(perform: deleteConversations)

            // Padding so the last row clears the input bar
            Color.clear
                .frame(height: 130)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(conversations[index]) }
        try? modelContext.save()
    }
}

// MARK: - ActionToast

private struct ActionToast: Identifiable {
    let id = UUID()
    let icon: String
    let message: String
    let color: Color
}

// MARK: - ConversationRow (unchanged)

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.displayTitle)
                    .font(Theme.headlineFont)
                    .lineLimit(1)

                if let last = conversation.lastMessage {
                    Text(last.content)
                        .font(Theme.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(conversation.updatedAt.relativeString)
                .font(Theme.captionFont)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
