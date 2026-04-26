import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sage_user_name") private var userName: String = ""
    @State private var showNameSetup        = false
    @State private var showColdStartVoice  = false
    @State private var selectedTab          = 0
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
        // Cold-start voice memory capture — shown every fresh launch so the
        // user can log a thought before doing anything else. Only shown when
        // setup is complete (bothModelsDownloaded) and name has been set.
        // The sheet is non-blocking: "Skip" dismisses it immediately.
        .sheet(isPresented: $showColdStartVoice) {
            VoiceMemoryCaptureView()
                .environmentObject(container)
        }
        .task {
            await container.bootstrap()
            if userName.isEmpty {
                showNameSetup = true
            } else if container.modelManager.bothModelsDownloaded {
                // Brief pause so the tab UI finishes rendering before the sheet
                // appears — prevents a jarring flash on launch.
                try? await Task.sleep(for: .milliseconds(600))
                showColdStartVoice = true
            }
            // Pull any pending Siri / Shortcuts / Action-Button query out of
            // UserDefaults and route it through the existing voice-chat channel.
            SageShortcutBridge.consumePending(into: container)
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
                // Pick up any Shortcut/Siri query queued while we were
                // backgrounded — covers the warm-launch path that .task
                // (which only fires once) would otherwise miss.
                SageShortcutBridge.consumePending(into: container)
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
        // Swipe left/right to switch tabs.
        //
        // Gesture priority: SwiftUI gives child-view gestures precedence over
        // parent-view gestures when both use .gesture() (not highPriorityGesture).
        // CalendarMemoryView attaches its month-swipe only to monthGrid, so:
        //   • Swipe on the calendar grid  → calendar changes month (child wins)
        //   • Swipe anywhere else         → tab switches (this gesture fires)
        //
        // The strict dx/dy ratio (3×) and 60pt threshold prevent vertical
        // ScrollViews from accidentally triggering a tab switch.
        .gesture(
            DragGesture(minimumDistance: 60)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) * 3, abs(dx) > 60 else { return }
                    if dx < 0 {
                        selectedTab = min(selectedTab + 1, 3)
                    } else {
                        selectedTab = max(selectedTab - 1, 0)
                    }
                }
        )
    }
}
