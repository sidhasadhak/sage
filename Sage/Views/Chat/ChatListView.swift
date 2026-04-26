import SwiftUI
import SwiftData

struct ChatListView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) var conversations: [Conversation]

    @State private var selectedConversation: Conversation?
    @State private var showingChat      = false
    @State private var showVoiceInput   = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if conversations.isEmpty {
                        voiceFirstEmptyState
                    } else {
                        conversationList
                    }
                }

                // Bottom action bar — voice is the primary (large, centred),
                // new-chat pencil is the secondary (smaller, trailing).
                bottomActionBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            .navigationTitle("Sage")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showingChat) {
                ChatView(conversation: selectedConversation)
                    .environmentObject(container)
            }
            .sheet(isPresented: $showVoiceInput) {
                ChatVoiceInputSheet { transcription in
                    container.pendingVoiceChatQuery = transcription
                }
                .environmentObject(container)
            }
            .onAppear {
                // Lazy model load: only starts when the user is on the Chat tab.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await container.loadChatModelIfNeeded()
                }
                if container.pendingVoiceChatQuery != nil {
                    selectedConversation = nil
                    showingChat = true
                }
            }
            .onChange(of: container.pendingVoiceChatQuery) { _, query in
                guard query != nil else { return }
                selectedConversation = nil
                showingChat = true
            }
        }
    }

    // MARK: - Bottom action bar

    private var bottomActionBar: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer()

            // ── Primary: voice button ──────────────────────────────────────
            Button {
                showVoiceInput = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 72, height: 72)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 12, x: 0, y: 6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel("Start voice chat")

            Spacer()

            // ── Secondary: new text chat ────────────────────────────────────
            Button {
                selectedConversation = nil
                showingChat = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 50, height: 50)
                        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 3)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .accessibilityLabel("New text chat")
        }
    }

    // MARK: - Empty state (voice-first)

    private var voiceFirstEmptyState: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // Mic graphic with outer ring
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.08))
                        .frame(width: 130, height: 130)
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 100, height: 100)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 10) {
                    Text("Talk to Sage")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Tap the mic below to speak.\nSage will understand and respond.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Subtle text-chat affordance
                Button {
                    selectedConversation = nil
                    showingChat = true
                } label: {
                    Label("Prefer typing?  Start a text chat", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
            }

            // Space for the bottom action bar so it doesn't cover content
            Spacer()
            Color.clear.frame(height: 110)
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

            // Bottom padding so the last row isn't hidden behind the action bar
            Color.clear
                .frame(height: 100)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(conversations[index])
        }
        try? modelContext.save()
    }
}

// MARK: - Conversation row

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
