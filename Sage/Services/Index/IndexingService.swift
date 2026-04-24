import Foundation
import Combine
import SwiftData
import Photos
import Contacts
import EventKit
import BackgroundTasks

@MainActor
final class IndexingService: ObservableObject {
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var lastIndexedAt: Date?

    private let modelContext: ModelContext
    private let embeddingService = EmbeddingService.shared
    private let searchEngine: SemanticSearchEngine
    private let spotlightService: SpotlightService
    private weak var llmService: LLMService?
    private weak var modelManager: ModelManager?
    private weak var googleCalendarService: GoogleCalendarService?

    // Shared geocoder — reusing a single instance avoids rate-limit errors.
    private let geocoder = CLGeocoder()

    // Maximum photos captioned per indexing run to prevent OOM / timeout.
    private let maxPhotosPerRun = 75

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
        modelManager: ModelManager? = nil,
        googleCalendarService: GoogleCalendarService? = nil
    ) {
        self.modelContext = modelContext
        self.searchEngine = searchEngine
        self.spotlightService = spotlightService
        self.llmService = llmService
        self.modelManager = modelManager
        self.googleCalendarService = googleCalendarService
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
        }

        await indexContacts()
        await indexCalendar()
        await indexAllNotes()
        // Vision captioning (SmolVLM swap) only runs in background — avoids OOM during
        // foreground use where both models would briefly compete for GPU RAM.
        await indexPhotos(enableCaptioning: isBackgroundRun)
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

        if let gcal = googleCalendarService {
            let gcalEvents = await gcal.syncedEvents(from: start, to: end)
            for gcalEvent in gcalEvents { await upsertGCalEventChunk(gcalEvent) }
        }
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

    private func upsertGCalEventChunk(_ event: GCalEvent) async {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let eventDate = event.start?.resolved
        var parts     = ["Event: \(event.summary ?? "Untitled")"]
        if let date = eventDate { parts.append("Date: \(formatter.string(from: date))") }
        if let loc  = event.location,    !loc.isEmpty    { parts.append("Location: \(loc)") }
        if let desc = event.description, !desc.isEmpty   { parts.append("Notes: \(desc.prefix(200))") }

        let content  = parts.joined(separator: ". ")
        let keywords = [event.summary, event.location].compactMap { $0 }.filter { !$0.isEmpty }

        await upsertChunk(
            sourceType: .event,
            sourceID: "gcal-\(event.id)",
            content: content,
            keywords: keywords,
            quality: .fast,
            sourceDate: eventDate
        )
    }

    // MARK: - Photos

    /// Indexes photos from the library.
    /// - Parameter enableCaptioning: When `true` (background only), loads SmolVLM to generate
    ///   semantic captions. Kept `false` during foreground runs to prevent OOM from a
    ///   two-model swap while Llama is already in GPU RAM.
    func indexPhotos(enableCaptioning: Bool = false) async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let since = UserDefaults.standard.object(forKey: DeltaKeys.photos) as? Date ?? periodStartDate
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@", since as CVarArg)

        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        var assetList: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in assetList.append(asset) }
        // Cap per run to prevent OOM / BGTask timeout
        let limited = Array(assetList.prefix(maxPhotosPerRun))

        // ─── SmolVLM swap-in (background only) ────────────────────────────
        // Only attempt when explicitly enabled (BGProcessingTask). During foreground
        // indexing we skip captions entirely — the device already has Llama in RAM
        // and loading SmolVLM on top risks hitting the memory limit.
        var didSwapToPhotoModel = false
        if enableCaptioning,
           let llm = llmService,
           let mgr = modelManager,
           let photoLocalModel = mgr.photoModel,
           !llm.isGenerating,
           !llm.isBackgroundProcessing {

            if llm.loadedModelID != ModelCatalog.photoAnalysisModel.id {
                // Unload Llama first to free GPU RAM, then load SmolVLM.
                llm.unloadModel()
                await llm.loadModel(from: photoLocalModel)
                didSwapToPhotoModel = llm.loadedModelID == ModelCatalog.photoAnalysisModel.id
            } else {
                didSwapToPhotoModel = true
            }
        }
        // ──────────────────────────────────────────────────────────────────

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        for asset in limited {
            await upsertPhotoChunk(asset, dateFormatter: dateFormatter)
        }

        // ─── Restore chat model (background only) ─────────────────────────
        if didSwapToPhotoModel,
           let llm = llmService,
           let chatLocalModel = modelManager?.chatModel {
            llm.unloadModel()
            await llm.loadModel(from: chatLocalModel)
        }
        // ──────────────────────────────────────────────────────────────────
    }

    private func upsertPhotoChunk(_ asset: PHAsset, dateFormatter: DateFormatter) async {
        let date = asset.creationDate.map { dateFormatter.string(from: $0) } ?? "unknown date"

        // Caption via SmolVLM — only when the photo-analysis model is active.
        var caption: String? = nil
        if let llm = llmService, llm.isPhotoAnalysisModelActive {
            let options = PHImageRequestOptions()
            options.isSynchronous      = false
            options.deliveryMode       = .fastFormat   // smaller thumbnail → faster, lower RAM
            options.isNetworkAccessAllowed = false

            let image = await withCheckedContinuation { continuation in
                var resumed = false
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 256, height: 256),
                    contentMode: .aspectFit,
                    options: options
                ) { image, _ in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
            if let image {
                caption = try? await llm.generateCaption(for: image)
            }
        }

        var parts = [caption ?? "Photo taken on \(date)"]

        if let location = asset.location {
            do {
                let locationStr: String
                if #available(iOS 26, *),
                   let request = MKReverseGeocodingRequest(location: location) {
                    let items     = try await request.mapItems
                    let placemark = items.first?.placemark
                    locationStr   = [placemark?.locality, placemark?.administrativeArea, placemark?.country]
                        .compactMap { $0 }.joined(separator: ", ")
                } else {
                    // 0.3s delay to respect CLGeocoder's 1-per-second rate limit.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let placemarks = try await geocoder.reverseGeocodeLocation(location)
                    let place      = placemarks.first
                    locationStr    = [place?.locality, place?.administrativeArea, place?.country]
                        .compactMap { $0 }.joined(separator: ", ")
                }
                if !locationStr.isEmpty { parts.append("at \(locationStr)") }
            } catch {}
        }

        let content  = parts.joined(separator: " ")
        var keywords: [String] = []
        if let caption { keywords.append(caption) }

        await upsertChunk(
            sourceType: .photo,
            sourceID: asset.localIdentifier,
            content: content,
            keywords: keywords,
            quality: .fast,
            sourceDate: asset.creationDate
        )
    }

    // MARK: - Notes

    /// Re-indexes all notes from SwiftData (called on every full index pass).
    func indexAllNotes() async {
        let descriptor = FetchDescriptor<Note>()
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
    }
}

import CoreLocation
import MapKit
