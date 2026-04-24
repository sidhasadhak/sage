import Foundation
import Combine
import SwiftData

@MainActor
final class AppContainer: ObservableObject {
    let modelContainer: ModelContainer
    let permissions: PermissionCoordinator
    let searchEngine: SemanticSearchEngine
    let spotlightService: SpotlightService
    let indexingService: IndexingService
    let contextBuilder: ContextBuilder
    let llmService: LLMService
    let modelManager: ModelManager
    let googleCalendarService: GoogleCalendarService
    let reminderService: ReminderCreationService
    let calendarEventService: CalendarEventCreationService

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let context = modelContainer.mainContext

        self.permissions = PermissionCoordinator()

        let search = SemanticSearchEngine()
        self.searchEngine = search

        let spotlight = SpotlightService()
        self.spotlightService = spotlight

        self.llmService = LLMService()
        self.modelManager = ModelManager(modelContext: context)

        let gcal = GoogleCalendarService()
        self.googleCalendarService = gcal

        self.indexingService = IndexingService(
            modelContext: context,
            searchEngine: search,
            spotlightService: spotlight,
            llmService: self.llmService,
            googleCalendarService: gcal
        )

        let builder = ContextBuilder(searchEngine: search)
        self.contextBuilder = builder

        self.reminderService = ReminderCreationService()
        self.calendarEventService = CalendarEventCreationService()
    }

    func bootstrap() async {
        await indexingService.loadSearchCache()
    }

    func loadActiveModelIfNeeded() async {
        guard !llmService.isReady, let active = modelManager.activeModel else { return }
        await llmService.loadModel(from: active)
    }
}
