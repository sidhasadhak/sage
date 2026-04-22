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

    var body: some View {
        VStack(spacing: 0) {
            messagesArea
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
                        suggestionsView
                            .padding(.top, 60)
                    }

                    ForEach(viewModel?.messages ?? [], id: \.id) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if viewModel?.isGenerating == true && viewModel?.streamingText.isEmpty == false {
                        StreamingBubble(text: viewModel?.streamingText ?? "")
                            .id("streaming")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel?.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel?.streamingText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    private var inputBar: some View {
        ChatInputBar(
            text: $inputText,
            isGenerating: viewModel?.isGenerating ?? false,
            isFocused: $isInputFocused
        ) {
            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            inputText = ""
            Task { await viewModel?.send(text) }
        }
    }

    private var suggestionsView: some View {
        VStack(spacing: 20) {
            // Show "no model" warning if needed
            if case .noModelSelected = container.llmService.state {
                noModelWarning
            } else if case .loading(let name) = container.llmService.state {
                loadingIndicator(name: name)
            } else {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor.opacity(0.6))

                Text("What's on your mind?")
                    .font(Theme.titleFont)

                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            inputText = suggestion
                            isInputFocused = true
                        }
                        .font(Theme.captionFont)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private var noModelWarning: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text("No model loaded")
                .font(Theme.titleFont)

            Text("Go to the Models tab to download a local AI model. Llama 3.2 3B is a great starting point.")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Open Models") {
                // Signal parent TabView to switch — handled via notification
                NotificationCenter.default.post(name: .switchToModelsTab, object: nil)
            }
            .buttonStyle(SageButtonStyle())
        }
    }

    private func loadingIndicator(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Loading \(name)…")
                .font(Theme.bodyFont)
                .foregroundStyle(.secondary)
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.aiBubble)
                    .clipShape(BubbleShape(isUser: false))
            }
            Spacer(minLength: 60)
        }
        .padding(.vertical, 2)
    }
}
