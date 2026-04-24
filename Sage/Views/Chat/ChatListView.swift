import SwiftUI
import SwiftData

struct ChatListView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) var conversations: [Conversation]

    @State private var selectedConversation: Conversation?
    @State private var showingChat = false
    @State private var showVoiceCapture = false

    // Tracks whether the cold-start voice capture has already been shown
    // this app session. Static so it survives tab switches / view re-creation.
    private static var coldStartCaptureShown = false

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("Sage")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        selectedConversation = nil
                        showingChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationDestination(isPresented: $showingChat) {
                ChatView(conversation: selectedConversation)
                    .environmentObject(container)
            }
            .sheet(isPresented: $showVoiceCapture) {
                // Voice capture saves to Notes/Reminders/Calendar — do NOT navigate to Chat.
                // The user can open a chat separately if they want to follow up.
            } content: {
                VoiceMemoryCaptureView()
                    .environmentObject(container)
            }
            .task {
                // Only show the voice capture sheet on the very first appearance
                // of this app session (cold start). Tab switches re-trigger .task
                // so we guard with a static flag.
                guard !ChatListView.coldStartCaptureShown else { return }
                ChatListView.coldStartCaptureShown = true
                showVoiceCapture = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Start a conversation")
                    .font(Theme.titleFont)
                Text("Ask about your photos, contacts, events, or anything on your mind.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button("New Chat") {
                selectedConversation = nil
                showingChat = true
            }
            .buttonStyle(SageButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
