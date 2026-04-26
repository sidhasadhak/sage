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
        .alert("Something went wrong", isPresented: Binding(
            get: { viewModel?.error != nil },
            set: { if !$0 { viewModel?.error = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel?.error = nil }
        } message: {
            Text(viewModel?.error ?? "")
        }
        .sheet(isPresented: $showVoiceInput) {
            ChatVoiceInputSheet { transcription in
                inputText = transcription
                isInputFocused = true
            }
            .environmentObject(container)
        }
        // v1.2 Phase-1 action preview. Driven entirely by the VM —
        // dismissal goes through cancelPendingAction so the runner
        // and audit log stay in sync with the UI.
        .sheet(item: Binding(
            get: { viewModel?.pendingActionPreview },
            set: { newValue in
                // Only treat a nil-set as a user-initiated dismissal
                // (drag-to-dismiss). Confirm/cancel buttons clear the
                // VM state directly and we mustn't double-cancel.
                if newValue == nil, viewModel?.pendingActionPreview != nil {
                    viewModel?.cancelPendingAction()
                }
            }
        )) { preview in
            ActionPreviewSheet(
                diff: preview.diff,
                displayName: preview.displayName,
                isExecuting: viewModel?.isExecutingAction ?? false,
                onConfirm: { Task { await viewModel?.confirmPendingAction() } },
                onCancel:  { viewModel?.cancelPendingAction() }
            )
        }
        .task {
            let vm = ChatViewModel(
                llmService: container.llmService,
                contextBuilder: container.contextBuilder,
                indexingService: container.indexingService,
                modelContext: modelContext,
                intentRouter:   container.intentRouter,
                actionRegistry: container.actionRegistry,
                actionRunner:   container.actionRunner,
                auditLogger:    container.auditLogger,
                memoryDecay:    container.memoryDecay,
                pevController:  container.pevController,
                agentLoop:      container.agentLoop
            )
            vm.loadOrCreateConversation(conversation)
            viewModel = vm

            // Pre-populate the input field if the voice recorder routed a
            // transcription here as a chat query. We clear the property so
            // navigating away & back doesn't re-fire it.
            if let query = container.pendingVoiceChatQuery {
                inputText = query
                isInputFocused = true
                container.pendingVoiceChatQuery = nil
            }
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
                    // Agent-loop planning status ("Thinking…", "Searching…")
                    if let status = viewModel?.agentStatus {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.65)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .id("agentStatus")
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

    // v1.2 Phase-1: the inline action banner is gone. Action confirmation
    // now lives in `ActionPreviewSheet` driven by `viewModel.pendingActionPreview`,
    // which is presented at the top level of `body` via `.sheet(item:)`.
    private var inputBar: some View {
        VStack(spacing: 0) {
            // Phase-3: Undo bar surfaces after a verified action commits.
            // Auto-hides via the VM's 8 s timer; tap Undo to roll back.
            if let receipt = viewModel?.lastReceipt {
                UndoBar(
                    receipt: receipt,
                    onUndo:    { Task { await viewModel?.undoLastAction() } },
                    onDismiss: { viewModel?.dismissUndo() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .animation(.spring(duration: 0.3), value: viewModel?.lastReceipt?.id)
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
                // Defensive: if `suggestions` ever gains duplicates or becomes
                // user-editable, id: \.self would collide. Offset is safe because
                // this view never mutates the array.
                ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
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
