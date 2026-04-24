import SwiftUI
import SwiftData

struct ChatView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    let conversation: Conversation?

    @State private var viewModel: ChatViewModel?
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    @State private var actionError: String?
    @State private var showVoiceInput = false

    var body: some View {
        VStack(spacing: 0) {
            messagesArea
            if let ids = viewModel?.photoAssetIDs, !ids.isEmpty {
                PhotoStripView(assetIDs: ids)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputBar
        }
        .navigationTitle(viewModel?.messages.isEmpty == false ? "Sage" : "New Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel?.isGenerating == true {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Stop") { viewModel?.stopGeneration() }
                        .foregroundStyle(.red)
                }
            }
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .sheet(isPresented: $showVoiceInput) {
            ChatVoiceInputSheet { transcription in
                inputText = transcription
                isInputFocused = true
            }
            .environmentObject(container)
        }
        .task {
            let vm = ChatViewModel(
                llmService: container.llmService,
                contextBuilder: container.contextBuilder,
                indexingService: container.indexingService,
                modelContext: modelContext
            )
            vm.loadOrCreateConversation(conversation)
            viewModel = vm
        }
    }

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if viewModel?.messages.isEmpty == true {
                        suggestionsView.padding(.top, 60)
                    }
                    ForEach(viewModel?.messages ?? [], id: \.id) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if viewModel?.isGenerating == true && viewModel?.streamingText.isEmpty == false {
                        StreamingBubble(text: viewModel?.streamingText ?? "").id("streaming")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel?.messages.count) { _, _ in scrollToBottom(proxy: proxy) }
            .onChange(of: viewModel?.streamingText) { _, _ in scrollToBottom(proxy: proxy) }
            .onAppear { scrollProxy = proxy }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let action = viewModel?.pendingAction {
                actionBanner(action)
            }
            ChatInputBar(
                text: $inputText,
                isGenerating: viewModel?.isGenerating ?? false,
                isFocused: $isInputFocused,
                onVoiceInput: { showVoiceInput = true }
            ) {
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                inputText = ""
                Task { await viewModel?.send(text) }
            }
        }
    }

    @ViewBuilder
    private func actionBanner(_ action: ChatViewModel.ChatAction) -> some View {
        switch action {
        case .createReminder(let title, let dueDate):
            HStack(spacing: 12) {
                Image(systemName: "bell.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Reminders?").font(.caption).foregroundStyle(.secondary)
                    Text(title).font(Theme.captionFont).lineLimit(1)
                }
                Spacer()
                Button("Add") {
                    Task {
                        do {
                            try await container.reminderService.createReminder(title: title, dueDate: dueDate)
                            viewModel?.dismissAction()
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                dismissButton
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.orange.opacity(0.1))

        case .scheduleCalendarEvent(let title, let startDate):
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.plus").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Calendar?").font(.caption).foregroundStyle(.secondary)
                    Text(title).font(Theme.captionFont).lineLimit(1)
                }
                Spacer()
                Button("Add") {
                    Task {
                        do {
                            try await container.calendarEventService.createEvent(title: title, startDate: startDate)
                            viewModel?.dismissAction()
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
                dismissButton
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.blue.opacity(0.1))
        }
    }

    private var dismissButton: some View {
        Button { viewModel?.dismissAction() } label: {
            Image(systemName: "xmark").font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var suggestionsView: some View {
        VStack(spacing: 20) {
            if case .noModelSelected = container.llmService.state {
                noModelWarning
            } else if case .loading(let name) = container.llmService.state {
                loadingIndicator(name: name)
            } else {
                voiceFirstEmptyState
            }
        }
        .padding(.horizontal, 32)
    }

    private var voiceFirstEmptyState: some View {
        VStack(spacing: 24) {
            Button {
                showVoiceInput = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 100, height: 100)
                    Circle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: 76, height: 76)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)

            Text("Tap to speak")
                .font(Theme.titleFont)
                .foregroundStyle(.primary)

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        inputText = suggestion
                        isInputFocused = true
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())
                }
            }
        }
    }

    private var noModelWarning: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Setting up AI models…").font(Theme.titleFont)
            Text("Sage is downloading its AI models in the background. This usually takes a few minutes on Wi-Fi.")
                .font(Theme.bodyFont).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView(value: container.modelManager.overallProgress)
                .padding(.horizontal, 40)
        }
    }

    private func loadingIndicator(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.4)
            Text("Loading \(name)…").font(Theme.bodyFont).foregroundStyle(.secondary)
        }
    }

    private let suggestions = [
        "Who do I have meetings with this week?",
        "What photos did I take in Paris?",
        "Find my notes about the project",
        "What did I save from last month?"
    ]

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if viewModel?.isGenerating == true {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let lastID = viewModel?.messages.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}


struct StreamingBubble: View {
    let text: String
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            SageAvatar()
            VStack(alignment: .leading, spacing: 4) {
                Text(text.isEmpty ? "..." : text)
                    .font(Theme.bodyFont)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.aiBubble)
                    .clipShape(BubbleShape(isUser: false))
            }
            Spacer(minLength: 60)
        }
        .padding(.vertical, 2)
    }
}
