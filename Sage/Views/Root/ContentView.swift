import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sage_user_name") private var userName: String = ""
    @State private var showNameSetup = false
    @State private var selectedTab   = 0
    @State private var evictionTask: Task<Void, Never>?

    var body: some View {
        Group {
            if container.modelManager.bothModelsDownloaded {
                mainTabs
            } else {
                ModelSetupView()
            }
        }
        .sheet(isPresented: $showNameSetup) {
            UserNameSetupView(userName: $userName)
        }
        .task {
            await container.bootstrap()
            if userName.isEmpty { showNameSetup = true }
            // Model loading is intentionally deferred — it happens lazily in ChatListView
            // when the user actually navigates to Chat. Loading at launch would spike
            // memory before the UI has settled, risking an OOM termination.
        }
        .onChange(of: container.pendingVoiceChatQuery) { _, query in
            // Voice recorder routed a transcription to chat — switch to the
            // Chat tab so ChatListView can pick it up and open a new chat.
            if query != nil { selectedTab = 0 }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Evict the LLM from GPU RAM after 3 minutes in background.
                evictionTask = Task {
                    try? await Task.sleep(for: .seconds(180))
                    guard !Task.isCancelled else { return }
                    container.llmService.unloadModel()
                }
            case .active:
                evictionTask?.cancel()
                evictionTask = nil
                // Do NOT reload here — ChatListView handles reloading when the user
                // returns to the Chat tab, keeping memory usage demand-driven.
            default:
                break
            }
        }
    }

    // MARK: - Main tab bar (shown only after setup)

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            ChatListView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)

            NotesListView()
                .tabItem { Label("Notes", systemImage: "note.text") }
                .tag(1)

            MemoryBrowserView()
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .tint(.accentColor)
    }
}
