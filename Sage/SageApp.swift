import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct SageApp: App {
    let container: AppContainer

    init() {
        let schema = Schema([
            Conversation.self,
            Message.self,
            Note.self,
            MemoryChunk.self,
            ImportedEmail.self,
            LocalModel.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let modelContainer = try! ModelContainer(for: schema, configurations: [config])
        let appContainer = AppContainer(modelContainer: modelContainer)
        container = appContainer

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.sage.app.indexing",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            let indexTask = Task {
                await appContainer.indexingService.indexAll()
                processingTask.setTaskCompleted(success: true)
            }
            processingTask.expirationHandler = { indexTask.cancel() }
        }
    }

    @AppStorage("app_color_scheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(container)
                .modelContainer(container.modelContainer)
                .tint(Color("AccentColor"))
                .preferredColorScheme(AppColorScheme(rawValue: colorSchemeRaw)?.colorScheme)
        }
    }
}
