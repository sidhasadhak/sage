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

    private enum DeltaKeys {
        static let photos   = "delta.lastPhotosIndexedAt"
        static let contacts = "delta.lastContactsIndexedAt"
        static let calendar = "delta.lastCalendarIndexedAt"
    }

    init(modelContext: ModelContext, searchEngine: SemanticSearchEngine, spotlightService: SpotlightService) {
        self.modelContext = modelContext
        self.searchEngine = searchEngine
        self.spotlightService = spotlightService
        lastIndexedAt = UserDefaults.standard.object(forKey: "lastIndexedAt") as? Date
    }

    func indexAll() async {
        guard !isIndexing else { return }
        isIndexing = true
        defer {
            isIndexing = false
            let now = Date()
            lastIndexedAt = now
            UserDefaults.standard.set(now, forKey: "lastIndexedAt")
            UserDefaults.standard.set(now, forKey: DeltaKeys.photos)
            UserDefaults.standard.set(now, forKey: DeltaKeys.contacts)
            UserDefaults.standard.set(now, forKey: DeltaKeys.calendar)
            scheduleBackgroundIndex()
        }

        await indexContacts()
        await indexCalendar()
        await indexPhotos()
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
            CNContactNoteKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        do {
            var contacts: [CNContact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                contacts.append(contact)
            }

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
        let org = contact.organizationName

        var contentParts = ["Contact: \(name)"]
        if !phones.isEmpty { contentParts.append("Phone: \(phones)") }
        if !emails.isEmpty { contentParts.append("Email: \(emails)") }
        if !org.isEmpty { contentParts.append("Organization: \(org)") }

        let content = contentParts.joined(separator: ". ")
        var keywords = [name, org].filter { !$0.isEmpty }
        keywords += emails.components(separatedBy: ", ")

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
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -180, to: now)!
        let end = Calendar.current.date(byAdding: .day, value: 180, to: now)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            await upsertEventChunk(event)
        }

        // Reminders
        store.fetchReminders(matching: store.predicateForReminders(in: nil)) { reminders in
            guard let reminders = reminders else { return }
            Task { @MainActor in
                for reminder in reminders {
                    await self.upsertReminderChunk(reminder)
                }
            }
        }
    }

    private func upsertEventChunk(_ event: EKEvent) async {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var parts = ["Event: \(event.title ?? "Untitled")"]
        parts.append("Date: \(formatter.string(from: event.startDate))")
        if let location = event.location, !location.isEmpty {
            parts.append("Location: \(location)")
        }
        if let notes = event.notes, !notes.isEmpty {
            parts.append("Notes: \(notes.prefix(200))")
        }

        let content = parts.joined(separator: ". ")
        let keywords = [event.title, event.location, event.calendar?.title]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        await upsertChunk(
            sourceType: .event,
            sourceID: event.eventIdentifier ?? UUID().uuidString,
            content: content,
            keywords: keywords,
            quality: .fast
        )
    }

    private func upsertReminderChunk(_ reminder: EKReminder) async {
        let status = reminder.isCompleted ? "completed" : "pending"
        var parts = ["Reminder: \(reminder.title ?? "Untitled")", "Status: \(status)"]

        if let due = reminder.dueDateComponents?.date {
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
            quality: .fast
        )
    }

    // MARK: - Photos

    func indexPhotos() async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        if let since = UserDefaults.standard.object(forKey: DeltaKeys.photos) as? Date {
            fetchOptions.predicate = NSPredicate(format: "creationDate > %@", since as CVarArg)
        } else {
            fetchOptions.fetchLimit = 500
        }

        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let geocoder = CLGeocoder()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        assets.enumerateObjects { [weak self] asset, _, _ in
            guard let self else { return }
            Task { @MainActor in
                await self.upsertPhotoChunk(asset, geocoder: geocoder, dateFormatter: dateFormatter)
            }
        }
    }

    private func upsertPhotoChunk(_ asset: PHAsset, geocoder: CLGeocoder, dateFormatter: DateFormatter) async {
        let date = asset.creationDate.map { dateFormatter.string(from: $0) } ?? "unknown date"
        var parts = ["Photo taken on \(date)"]

        if let location = asset.location {
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                if let place = placemarks.first {
                    let locationStr = [place.locality, place.administrativeArea, place.country]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                    if !locationStr.isEmpty { parts.append("at \(locationStr)") }
                }
            } catch {}
        }

        let content = parts.joined(separator: " ")
        await upsertChunk(
            sourceType: .photo,
            sourceID: asset.localIdentifier,
            content: content,
            keywords: [],
            quality: .fast
        )
    }

    // MARK: - Notes

    func indexNote(_ note: Note) async {
        let content = [
            note.title.isEmpty ? nil : "Note title: \(note.title)",
            note.body.isEmpty ? nil : note.body,
            note.transcription.map { "Voice transcription: \($0)" }
        ].compactMap { $0 }.joined(separator: ". ")

        guard !content.isEmpty else { return }

        let chunk = await upsertChunk(
            sourceType: .note,
            sourceID: note.id.uuidString,
            content: content,
            keywords: note.title.components(separatedBy: .whitespacesAndNewlines),
            quality: .contextual
        )
        if let chunk {
            note.memoryChunk = chunk
        }
    }

    func removeNoteChunk(_ note: Note) {
        if let chunk = note.memoryChunk {
            Task { await searchEngine.removeFromCache(id: chunk.id) }
            modelContext.delete(chunk)
        }
    }

    // MARK: - Core

    @discardableResult
    private func upsertChunk(
        sourceType: MemoryChunk.SourceType,
        sourceID: String,
        content: String,
        keywords: [String],
        quality: EmbeddingService.Quality
    ) async -> MemoryChunk? {
        // Check for existing
        let descriptor = FetchDescriptor<MemoryChunk>(
            predicate: #Predicate { $0.sourceID == sourceID }
        )
        let existing = try? modelContext.fetch(descriptor).first

        // Content-hash skip: if the text hasn't changed, avoid re-embedding (the expensive step)
        if let existing, existing.content == content {
            indexedCount += 1
            return existing
        }

        let chunk = existing ?? {
            let c = MemoryChunk(sourceType: sourceType, sourceID: sourceID, content: content, keywords: keywords)
            modelContext.insert(c)
            return c
        }()

        chunk.content = content
        chunk.keywords = keywords
        chunk.updatedAt = Date()

        // Compute embedding
        if let vector = try? await embeddingService.embed(text: content, quality: quality) {
            chunk.embeddingData = EmbeddingService.pack(vector)
            await searchEngine.addToCache(chunk: chunk)
        }

        // Spotlight
        if !chunk.isSpotlightIndexed {
            await spotlightService.index(chunk: chunk)
            chunk.isSpotlightIndexed = true
        }

        try? modelContext.save()
        indexedCount += 1
        return chunk
    }

    // MARK: - Load Cache

    func loadSearchCache() async {
        let descriptor = FetchDescriptor<MemoryChunk>()
        guard let chunks = try? modelContext.fetch(descriptor) else { return }
        await searchEngine.loadCache(chunks: chunks)
    }
}

import CoreLocation
