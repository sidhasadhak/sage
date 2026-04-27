import Foundation
import Combine
import SwiftData
import Contacts
import EventKit
import BackgroundTasks

/// Lightweight diagnostic record for the in-app Diagnostics screen.
/// Intentionally tiny — we keep at most `IndexingService.logCapacity`
/// entries in a ring buffer so this never grows unbounded.
struct IndexingLogEntry: Identifiable, Equatable {
    enum Severity { case info, warning, error }
    let id = UUID()
    let date: Date
    let severity: Severity
    let message: String
}

@MainActor
final class IndexingService: ObservableObject {
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var lastIndexedAt: Date?

    /// Surfaces the most recent indexing failure (nil until something fails).
    /// Cleared on the next successful pass. Read by DiagnosticsView so users
    /// can finally see *why* indexing stalled instead of guessing.
    @Published private(set) var lastError: String?

    /// Ring buffer of recent indexing events for the Diagnostics screen.
    /// Writes are O(1); we trim from the head when capacity is exceeded.
    @Published private(set) var recentLog: [IndexingLogEntry] = []
    static let logCapacity = 100

    func log(_ message: String, severity: IndexingLogEntry.Severity = .info) {
        let entry = IndexingLogEntry(date: Date(), severity: severity, message: message)
        recentLog.append(entry)
        if recentLog.count > Self.logCapacity {
            recentLog.removeFirst(recentLog.count - Self.logCapacity)
        }
        if severity == .error { lastError = message }
    }

    private let modelContext: ModelContext
    private let embeddingService = EmbeddingService.shared
    private let searchEngine: SemanticSearchEngine
    private let spotlightService: SpotlightService
    private weak var llmService: LLMService?
    private weak var modelManager: ModelManager?
    /// v1.2 Phase-2: optional decay sweeper. The indexAll pass calls
    /// runIfDue at the end so memory garbage-collection happens
    /// alongside fresh-data ingestion, sharing one wake-up cycle.
    weak var memoryDecay: MemoryDecay?

    // Photos are indexed in small batches with explicit yields between each
    // batch so the GPU can release tile memory and the OS can reclaim cache.
    // No caps — every photo in the indexing period is processed; we just
    // pace the work so a large library doesn't trigger OOM.
    // sage-slim: photoBatchSize removed with the photo indexing path.

    private enum DeltaKeys {
        static let photos   = "delta.lastPhotosIndexedAt"
        static let contacts = "delta.lastContactsIndexedAt"
        static let calendar = "delta.lastCalendarIndexedAt"
        static let modelID  = "delta.lastIndexedModelID"
    }

    private var indexingPeriodMonths: Int {
        let v = UserDefaults.standard.integer(forKey: "indexing_period_months")
        return v > 0 ? v : 3
    }

    private var periodStartDate: Date {
        Calendar.current.date(byAdding: .month, value: -indexingPeriodMonths, to: Date()) ?? Date()
    }

    init(
        modelContext: ModelContext,
        searchEngine: SemanticSearchEngine,
        spotlightService: SpotlightService,
        llmService: LLMService? = nil,
        modelManager: ModelManager? = nil
    ) {
        self.modelContext = modelContext
        self.searchEngine = searchEngine
        self.spotlightService = spotlightService
        self.llmService = llmService
        self.modelManager = modelManager
        lastIndexedAt = UserDefaults.standard.object(forKey: "lastIndexedAt") as? Date
    }

    // MARK: - Full index pass

    /// - Parameters:
    ///   - currentModelID: The active chat model's catalog ID (used to detect model changes).
    ///   - isBackgroundRun: Pass `true` only from a BGProcessingTask (device charging, idle).
    ///     When `true`, SmolVLM is loaded for photo captioning.
    ///     When `false` (foreground tap from Settings), photo captioning is skipped to avoid
    ///     the memory spike of swapping two large models while the app is in use.
    func indexAll(currentModelID: String? = nil, isBackgroundRun: Bool = false) async {
        guard !isIndexing else { return }
        isIndexing = true
        lastError = nil
        log("Indexing started (\(isBackgroundRun ? "background" : "foreground"))")

        // When the chat model changes, photo captions become stale — clear and re-caption.
        let storedModelID = UserDefaults.standard.string(forKey: DeltaKeys.modelID)
        if let currentModelID, currentModelID != storedModelID {
            await clearChunks(ofType: .photo)
            UserDefaults.standard.removeObject(forKey: DeltaKeys.photos)
        }

        defer {
            isIndexing = false
            let now = Date()
            lastIndexedAt = now
            UserDefaults.standard.set(now, forKey: "lastIndexedAt")
            UserDefaults.standard.set(now, forKey: DeltaKeys.photos)
            UserDefaults.standard.set(now, forKey: DeltaKeys.contacts)
            UserDefaults.standard.set(now, forKey: DeltaKeys.calendar)
            if let currentModelID {
                UserDefaults.standard.set(currentModelID, forKey: DeltaKeys.modelID)
            }
            scheduleBackgroundIndex()
            log("Indexing finished — \(indexedCount) chunks total")
        }

        // sage-slim: photo / vision indexing removed.
        await indexCalendar()
        await indexAllNotes()
        await Task.yield()

        // v1.2 Phase-2: piggy-back the daily decay sweep on the
        // indexing wake-up. Internally rate-limited to once per ~20h.
        if let decay = memoryDecay, let result = await decay.runIfDue() {
            log("Decay pass: demoted=\(result.demoted) evicted=\(result.evicted) skipped=\(result.skipped) pinned=\(result.pinnedSeen)")
        }
    }

    // MARK: - Clear all memories

    /// Wipes every indexed `MemoryChunk` from SwiftData, resets all delta
    /// trackers, clears the in-memory search cache, and removes Spotlight
    /// entries. After this returns, the Memory tab shows the empty state.
    func clearAllMemories() async {
        // 1. Delete all MemoryChunk rows from SwiftData.
        let descriptor = FetchDescriptor<MemoryChunk>()
        if let all = try? modelContext.fetch(descriptor) {
            for chunk in all { modelContext.delete(chunk) }
            try? modelContext.save()
        }
        // 2. Detach any Note → MemoryChunk references that survived the delete.
        let noteDescriptor = FetchDescriptor<Note>()
        if let notes = try? modelContext.fetch(noteDescriptor) {
            for note in notes { note.memoryChunk = nil }
            try? modelContext.save()
        }
        // 3. Reset semantic search cache + Spotlight.
        await searchEngine.invalidateCache()
        await spotlightService.removeAll()
        // 4. Reset delta trackers so the next indexing pass starts fresh.
        UserDefaults.standard.removeObject(forKey: DeltaKeys.photos)
        UserDefaults.standard.removeObject(forKey: DeltaKeys.contacts)
        UserDefaults.standard.removeObject(forKey: DeltaKeys.calendar)
        UserDefaults.standard.removeObject(forKey: DeltaKeys.modelID)
        UserDefaults.standard.removeObject(forKey: "lastIndexedAt")
        // 5. Reset on-screen counters.
        indexedCount = 0
        lastIndexedAt = nil
        log("All memories cleared", severity: .warning)
    }

    private func clearChunks(ofType type: MemoryChunk.SourceType) async {
        let descriptor = FetchDescriptor<MemoryChunk>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        for chunk in all where chunk.sourceType == type {
            await searchEngine.removeFromCache(id: chunk.id)
            modelContext.delete(chunk)
        }
        try? modelContext.save()
    }

    func scheduleBackgroundIndex() {
        let request = BGProcessingTaskRequest(identifier: "com.sage.app.indexing")
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Contacts

    func indexContacts() async {
        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        do {
            let contacts: [CNContact] = try await Task.detached(priority: .utility) {
                var result: [CNContact] = []
                try store.enumerateContacts(with: request) { contact, _ in result.append(contact) }
                return result
            }.value

            for contact in contacts {
                await upsertContactChunk(contact)
            }
        } catch {
            print("Contact indexing error: \(error)")
        }
    }

    private func upsertContactChunk(_ contact: CNContact) async {
        let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let phones = contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: ", ")
        let emails = contact.emailAddresses.map { $0.value as String }.joined(separator: ", ")
        let org    = contact.organizationName

        var contentParts = ["Contact: \(name)"]
        if !phones.isEmpty { contentParts.append("Phone: \(phones)") }
        if !emails.isEmpty { contentParts.append("Email: \(emails)") }
        if !org.isEmpty    { contentParts.append("Organization: \(org)") }

        let content  = contentParts.joined(separator: ". ")
        var keywords = [name, org].filter { !$0.isEmpty }
        keywords    += emails.components(separatedBy: ", ")

        await upsertChunk(
            sourceType: .contact,
            sourceID: contact.identifier,
            content: content,
            keywords: keywords,
            quality: .fast
        )
    }

    // MARK: - Calendar

    func indexCalendar() async {
        let store = EKEventStore()
        let now   = Date()
        let start = periodStartDate
        let end   = Calendar.current.date(byAdding: .month, value: 3, to: now)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events    = store.events(matching: predicate)

        for event in events {
            await upsertEventChunk(event)
        }

        store.fetchReminders(matching: store.predicateForReminders(in: nil)) { reminders in
            guard let reminders = reminders else { return }
            Task { @MainActor in
                for reminder in reminders { await self.upsertReminderChunk(reminder) }
            }
        }

        // Note: Google Calendar events added to the user's iOS account
        // surface here through EventKit automatically — no third-party
        // OAuth client required. (See quick-win #1: removed GoogleCalendarService.)
    }

    private func upsertEventChunk(_ event: EKEvent) async {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var parts = ["Event: \(event.title ?? "Untitled")"]
        parts.append("Date: \(formatter.string(from: event.startDate))")
        if let location = event.location, !location.isEmpty { parts.append("Location: \(location)") }
        if let notes = event.notes, !notes.isEmpty { parts.append("Notes: \(notes.prefix(200))") }

        let content  = parts.joined(separator: ". ")
        let keywords = [event.title, event.location, event.calendar?.title]
            .compactMap { $0 }.filter { !$0.isEmpty }

        await upsertChunk(
            sourceType: .event,
            sourceID: event.eventIdentifier ?? UUID().uuidString,
            content: content,
            keywords: keywords,
            quality: .fast,
            sourceDate: event.startDate
        )
    }

    private func upsertReminderChunk(_ reminder: EKReminder) async {
        let status  = reminder.isCompleted ? "completed" : "pending"
        var parts   = ["Reminder: \(reminder.title ?? "Untitled")", "Status: \(status)"]
        let dueDate = reminder.dueDateComponents?.date

        if let due = dueDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            parts.append("Due: \(formatter.string(from: due))")
        }

        let content = parts.joined(separator: ". ")
        await upsertChunk(
            sourceType: .reminder,
            sourceID: reminder.calendarItemIdentifier,
            content: content,
            keywords: [reminder.title].compactMap { $0 },
            quality: .fast,
            sourceDate: dueDate
        )
    }


    // MARK: - Notes

    /// Re-indexes notes from SwiftData. Only notes created/updated within
    /// the configured indexing period are indexed — older notes stay in the
    /// app but aren't part of the active memory index, matching the user's
    /// expectation that the period scope applies uniformly.
    func indexAllNotes() async {
        let cutoff = periodStartDate
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.updatedAt >= cutoff }
        )
        guard let notes = try? modelContext.fetch(descriptor) else { return }
        for note in notes { await indexNote(note) }
    }

    /// labels: pre-generated LLM labels. If nil, falls back to splitting the note title.
    func indexNote(_ note: Note, labels: [String]? = nil) async {
        let content = [
            note.title.isEmpty ? nil : "Note title: \(note.title)",
            note.body.isEmpty  ? nil : note.body,
            note.transcription.map { "Voice transcription: \($0)" }
        ].compactMap { $0 }.joined(separator: ". ")

        guard !content.isEmpty else { return }

        let keywords = labels?.isEmpty == false
            ? labels!
            : note.title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        let chunk = await upsertChunk(
            sourceType: .note,
            sourceID: note.id.uuidString,
            content: content,
            keywords: keywords,
            quality: .contextual
        )
        if let chunk { note.memoryChunk = chunk }
    }

    func removeNoteChunk(_ note: Note) {
        if let chunk = note.memoryChunk {
            Task { await searchEngine.removeFromCache(id: chunk.id) }
            modelContext.delete(chunk)
        }
    }

    // MARK: - Entity graph

    /// Runs the LLM entity extractor over unprocessed chunks (background, idle-only).
    func buildEntityGraph() async {
        guard let llm = llmService else { return }
        let descriptor = FetchDescriptor<MemoryChunk>()
        guard let all = try? modelContext.fetch(descriptor) else { return }

        // Only process chunks that haven't been entity-analysed yet.
        let unprocessed = all.filter { $0.entities == nil }.prefix(20)
        for chunk in unprocessed {
            let entities = await llm.extractEntities(from: chunk.content)
            chunk.entities = entities
        }
        try? modelContext.save()
    }

    // MARK: - Core upsert

    @discardableResult
    private func upsertChunk(
        sourceType: MemoryChunk.SourceType,
        sourceID: String,
        content: String,
        keywords: [String],
        quality: EmbeddingService.Quality,
        sourceDate: Date? = nil
    ) async -> MemoryChunk? {
        let descriptor = FetchDescriptor<MemoryChunk>(
            predicate: #Predicate { $0.sourceID == sourceID }
        )
        let existing = try? modelContext.fetch(descriptor).first

        // Content-hash skip: avoid re-embedding if text hasn't changed.
        if let existing, existing.content == content {
            if let sourceDate, existing.sourceDate == nil {
                existing.sourceDate = sourceDate
                try? modelContext.save()
            }
            indexedCount += 1
            return existing
        }

        let chunk = existing ?? {
            let c = MemoryChunk(
                sourceType: sourceType, sourceID: sourceID,
                content: content, keywords: keywords, sourceDate: sourceDate
            )
            modelContext.insert(c)
            return c
        }()

        chunk.content    = content
        chunk.keywords   = keywords
        chunk.updatedAt  = Date()
        if let sourceDate { chunk.sourceDate = sourceDate }

        if let vector = try? await embeddingService.embed(text: content, quality: quality) {
            chunk.embeddingData = EmbeddingService.pack(vector)
            await searchEngine.addToCache(chunk: chunk)
        }

        if !chunk.isSpotlightIndexed {
            await spotlightService.index(chunk: chunk)
            chunk.isSpotlightIndexed = true
        }

        try? modelContext.save()
        indexedCount += 1
        return chunk
    }

    // MARK: - Load cache

    func loadSearchCache() async {
        let descriptor = FetchDescriptor<MemoryChunk>()
        guard let chunks = try? modelContext.fetch(descriptor) else { return }
        await searchEngine.loadCache(chunks: chunks)

        // One-shot migration: re-pack any chunks still holding legacy Float32
        // embedding blobs into the new int8-quantized format (~4× smaller).
        // Idempotent — guarded by a UserDefaults flag and a per-row format
        // check, so subsequent launches return immediately.
        await compactLegacyEmbeddingsIfNeeded(chunks: chunks)
    }

    private func compactLegacyEmbeddingsIfNeeded(chunks: [MemoryChunk]) async {
        let migrationKey = "delta.embeddingsQuantizedV1"
        if UserDefaults.standard.bool(forKey: migrationKey) { return }

        var migrated = 0
        for chunk in chunks {
            guard let data = chunk.embeddingData,
                  !EmbeddingService.isQuantized(data) else { continue }
            let vector = EmbeddingService.unpack(data)
            guard !vector.isEmpty else { continue }
            chunk.embeddingData = EmbeddingService.pack(vector)
            migrated += 1
            // Yield occasionally so a large library doesn't block the actor.
            if migrated % 200 == 0 { await Task.yield() }
        }
        if migrated > 0 { try? modelContext.save() }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
}

// sage-slim: CoreLocation / MapKit / Photos imports removed with the
// photo indexing pipeline.
