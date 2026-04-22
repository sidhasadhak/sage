import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var evictionTask: Task<Void, Never>?

    var body: some View {
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

            ModelLibraryView()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(3)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(4)
        }
        .tint(.accentColor)
        .task {
            await container.bootstrap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToModelsTab)) { _ in
            selectedTab = 3
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Evict the LLM from GPU RAM after 3 minutes in background
                evictionTask = Task {
                    try? await Task.sleep(for: .seconds(180))
                    guard !Task.isCancelled else { return }
                    container.llmService.unloadModel()
                }
            case .active:
                evictionTask?.cancel()
                evictionTask = nil
            default:
                break
            }
        }
    }
}
