import SwiftUI
import SwiftData
import UIKit
import EventKit

struct MemoryBrowserView: View {
    @EnvironmentObject var container: AppContainer
    @Environment(\.modelContext) var modelContext
    @Query var allChunks: [MemoryChunk]
    @Query var notes: [Note]

    @State private var viewModel: MemoryViewModel?
    @State private var searchText = ""
    @State private var selectedType: MemoryChunk.SourceType? = nil
    @State private var selectedNote: Note?
    @State private var selectedPhotoID: String?
    @State private var selectedContactID: String?
    @State private var sortKey: SortKey = .sourceDate
    @State private var sortAscending = false
    @State private var expandedYears: Set<String> = []
    @State private var expandedMonths: Set<String> = []
    @State private var expandedWeeks: Set<String> = []
    @State private var expandedDays: Set<String> = []

    // MARK: - Sort key

    enum SortKey: String, CaseIterable, Identifiable {
        case sourceDate = "Source Date"
        case modified = "Date Modified"
        case created = "Date Created"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .sourceDate: return "calendar"
            case .modified:   return "pencil.circle"
            case .created:    return "clock"
            }
        }
        func date(for chunk: MemoryChunk) -> Date {
            switch self {
            case .sourceDate: return chunk.sourceDate ?? chunk.updatedAt
            case .modified:   return chunk.updatedAt
            case .created:    return chunk.createdAt
            }
        }
    }

    // MARK: - Hierarchy data structures

    struct DayGroup: Identifiable {
        let id: String; let label: String; let chunks: [MemoryChunk]
    }
    struct WeekGroup: Identifiable {
        let id: String; let label: String; let days: [DayGroup]
        var count: Int { days.reduce(0) { $0 + $1.chunks.count } }
    }
    struct MonthGroup: Identifiable {
        let id: String; let label: String; let weeks: [WeekGroup]
        var count: Int { weeks.reduce(0) { $0 + $1.count } }
    }
    struct YearGroup: Identifiable {
        let id: String; let label: String; let months: [MonthGroup]
        var count: Int { months.reduce(0) { $0 + $1.count } }
    }

    enum HierarchyRow: Identifiable {
        case year(key: String, label: String, count: Int, expanded: Bool)
        case month(key: String, label: String, count: Int, expanded: Bool)
        case week(key: String, label: String, count: Int, expanded: Bool)
        case day(key: String, label: String, count: Int, expanded: Bool)
        case chunk(MemoryChunk)
        var id: String {
            switch self {
            case .year(let k, _, _, _):  "y-\(k)"
            case .month(let k, _, _, _): "m-\(k)"
            case .week(let k, _, _, _):  "w-\(k)"
            case .day(let k, _, _, _):   "d-\(k)"
            case .chunk(let c):          "c-\(c.id)"
            }
        }
    }

    // MARK: - Formatters

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()
    private static let weekStartFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    // MARK: - Computed

    var filteredChunks: [MemoryChunk] {
        var chunks = allChunks
        if let type = selectedType {
            chunks = chunks.filter { $0.sourceType == type }
        }
        if !searchText.isEmpty {
            chunks = chunks.filter {
                $0.content.localizedCaseInsensitiveContains(searchText) ||
                $0.keywords.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return chunks.sorted {
            let d0 = sortKey.date(for: $0), d1 = sortKey.date(for: $1)
            return sortAscending ? d0 < d1 : d0 > d1
        }
    }

    var yearGroups: [YearGroup] {
        let cal = Calendar.current
        let chunks = filteredChunks
        guard !chunks.isEmpty else { return [] }

        let byYear = Dictionary(grouping: chunks) { chunk -> String in
            String(cal.component(.year, from: sortKey.date(for: chunk)))
        }
        let yearKeys = byYear.keys.sorted { sortAscending ? $0 < $1 : $0 > $1 }

        return yearKeys.map { yearKey in
            let yearChunks = byYear[yearKey]!

            let byMonth = Dictionary(grouping: yearChunks) { chunk -> String in
                let d = sortKey.date(for: chunk)
                return String(format: "%04d-%02d",
                    cal.component(.year, from: d),
                    cal.component(.month, from: d))
            }
            let monthKeys = byMonth.keys.sorted { sortAscending ? $0 < $1 : $0 > $1 }

            let months: [MonthGroup] = monthKeys.map { monthKey in
                let monthChunks = byMonth[monthKey]!

                let byWeek = Dictionary(grouping: monthChunks) { chunk -> String in
                    let d = sortKey.date(for: chunk)
                    return String(format: "%04d-W%02d",
                        cal.component(.yearForWeekOfYear, from: d),
                        cal.component(.weekOfYear, from: d))
                }
                let weekKeys = byWeek.keys.sorted { sortAscending ? $0 < $1 : $0 > $1 }

                let weeks: [WeekGroup] = weekKeys.map { weekKey in
                    let weekChunks = byWeek[weekKey]!

                    let byDay = Dictionary(grouping: weekChunks) { chunk -> String in
                        let d = sortKey.date(for: chunk)
                        return String(format: "%04d-%02d-%02d",
                            cal.component(.year, from: d),
                            cal.component(.month, from: d),
                            cal.component(.day, from: d))
                    }
                    let dayKeys = byDay.keys.sorted { sortAscending ? $0 < $1 : $0 > $1 }

                    let days: [DayGroup] = dayKeys.map { dayKey in
                        let dayChunks = byDay[dayKey]!
                        let label = Self.dayFormatter.string(from: sortKey.date(for: dayChunks[0]))
                        return DayGroup(id: dayKey, label: label, chunks: dayChunks)
                    }

                    let weekLabel = makeWeekLabel(for: sortKey.date(for: weekChunks[0]), cal: cal)
                    return WeekGroup(id: weekKey, label: weekLabel, days: days)
                }

                let monthLabel = Self.monthFormatter.string(from: sortKey.date(for: monthChunks[0]))
                return MonthGroup(id: monthKey, label: monthLabel, weeks: weeks)
            }

            return YearGroup(id: yearKey, label: yearKey, months: months)
        }
    }

    var hierarchyRows: [HierarchyRow] {
        var rows: [HierarchyRow] = []
        for year in yearGroups {
            let yExp = expandedYears.contains(year.id)
            rows.append(.year(key: year.id, label: year.label, count: year.count, expanded: yExp))
            guard yExp else { continue }
            for month in year.months {
                let mExp = expandedMonths.contains(month.id)
                rows.append(.month(key: month.id, label: month.label, count: month.count, expanded: mExp))
                guard mExp else { continue }
                for week in month.weeks {
                    let wExp = expandedWeeks.contains(week.id)
                    rows.append(.week(key: week.id, label: week.label, count: week.count, expanded: wExp))
                    guard wExp else { continue }
                    for day in week.days {
                        let dExp = expandedDays.contains(day.id)
                        rows.append(.day(key: day.id, label: day.label, count: day.chunks.count, expanded: dExp))
                        guard dExp else { continue }
                        for chunk in day.chunks {
                            rows.append(.chunk(chunk))
                        }
                    }
                }
            }
        }
        return rows
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                typeFilterBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                if filteredChunks.isEmpty { emptyState } else { chunkList }
            }
            .navigationTitle("Memory")
            .searchable(text: $searchText, prompt: "Search your memories")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    sortMenu
                }
            }
            .onChange(of: searchText) { _, _ in Task { await viewModel?.search() } }
            .onChange(of: allChunks.count) { _, _ in autoExpandMostRecent() }
            .onChange(of: sortKey) { _, _ in resetExpansion() }
            .onChange(of: selectedType) { _, _ in resetExpansion() }
            .task {
                viewModel = MemoryViewModel(searchEngine: container.searchEngine, modelContext: modelContext)
                autoExpandMostRecent()
            }
        }
        .sheet(item: $selectedNote) { note in
            NoteEditorView(note: note, viewModel: nil)
        }
        .fullScreenCover(item: Binding(
            get: { selectedPhotoID.map { IdentifiableString(value: $0) } },
            set: { selectedPhotoID = $0?.value }
        )) { item in
            PhotoViewerView(assetID: item.value)
        }
        .sheet(item: Binding(
            get: { selectedContactID.map { IdentifiableString(value: $0) } },
            set: { selectedContactID = $0?.value }
        )) { item in
            ContactViewerView(contactID: item.value)
                .ignoresSafeArea()
        }
    }

    // MARK: - Toolbar

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortKey) {
                ForEach(SortKey.allCases) { key in
                    Label(key.rawValue, systemImage: key.systemImage).tag(key)
                }
            }
            .pickerStyle(.inline)

            Picker("Direction", selection: $sortAscending) {
                Label("Newest First", systemImage: "arrow.down").tag(false)
                Label("Oldest First", systemImage: "arrow.up").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }

    // MARK: - Filter bar

    private var typeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", icon: "square.grid.2x2", isSelected: selectedType == nil) {
                    selectedType = nil
                }
                ForEach(MemoryChunk.SourceType.allCases, id: \.self) { type in
                    FilterChip(
                        label: type.rawValue.capitalized,
                        icon: iconFor(type),
                        isSelected: selectedType == type
                    ) {
                        selectedType = selectedType == type ? nil : type
                    }
                }
            }
        }
    }

    // MARK: - List

    private var chunkList: some View {
        List {
            ForEach(hierarchyRows) { row in
                switch row {
                case .year(let key, let label, let count, let expanded):
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedYears.contains(key) { expandedYears.remove(key) }
                            else { expandedYears.insert(key) }
                        }
                    } label: {
                        yearHeaderLabel(label: label, count: count, expanded: expanded)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))

                case .month(let key, let label, let count, let expanded):
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedMonths.contains(key) { expandedMonths.remove(key) }
                            else { expandedMonths.insert(key) }
                        }
                    } label: {
                        groupHeaderLabel(label: label, count: count, expanded: expanded, level: 1)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 32, bottom: 2, trailing: 16))

                case .week(let key, let label, let count, let expanded):
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedWeeks.contains(key) { expandedWeeks.remove(key) }
                            else { expandedWeeks.insert(key) }
                        }
                    } label: {
                        groupHeaderLabel(label: label, count: count, expanded: expanded, level: 2)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 3, leading: 48, bottom: 2, trailing: 16))

                case .day(let key, let label, let count, let expanded):
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedDays.contains(key) { expandedDays.remove(key) }
                            else { expandedDays.insert(key) }
                        }
                    } label: {
                        groupHeaderLabel(label: label, count: count, expanded: expanded, level: 3)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 3, leading: 62, bottom: 2, trailing: 16))

                case .chunk(let chunk):
                    MemoryChunkRow(chunk: chunk, onTap: { openChunk(chunk) })
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 72, bottom: 2, trailing: 16))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                viewModel?.deleteChunk(chunk)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Header row views

    @ViewBuilder
    private func yearHeaderLabel(label: String, count: Int, expanded: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14)
            Text(label)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.1))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func groupHeaderLabel(label: String, count: Int, expanded: Bool, level: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: level == 1 ? 10 : 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(label)
                .font(level == 1 ? Theme.captionFont : .caption2)
                .fontWeight(level == 1 ? .medium : .regular)
                .foregroundStyle(level == 1 ? Color.primary.opacity(0.7) : Color.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func makeWeekLabel(for date: Date, cal: Calendar) -> String {
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        comps.weekday = 2 // Monday
        let monday = cal.date(from: comps) ?? date
        return "Week of \(Self.weekStartFormatter.string(from: monday))"
    }

    private func autoExpandMostRecent() {
        guard let topYear = yearGroups.first else { return }
        expandedYears.insert(topYear.id)
    }

    private func resetExpansion() {
        expandedYears.removeAll()
        expandedMonths.removeAll()
        expandedWeeks.removeAll()
        expandedDays.removeAll()
        autoExpandMostRecent()
    }

    private func openChunk(_ chunk: MemoryChunk) {
        switch chunk.sourceType {
        case .photo:
            selectedPhotoID = chunk.sourceID

        case .contact:
            selectedContactID = chunk.sourceID

        case .event:
            let store = EKEventStore()
            if let event = store.event(withIdentifier: chunk.sourceID) {
                let ts = event.startDate.timeIntervalSinceReferenceDate
                if let url = URL(string: "calshow:\(ts)") {
                    UIApplication.shared.open(url)
                }
            } else if let url = URL(string: "calshow://") {
                UIApplication.shared.open(url)
            }

        case .reminder:
            if let url = URL(string: "x-apple-reminderkit://") {
                UIApplication.shared.open(url)
            }

        case .note:
            selectedNote = notes.first { $0.memoryChunk?.id == chunk.id }

        case .conversation, .email:
            break
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(allChunks.isEmpty ? "No memories indexed yet" : "No results")
                .font(Theme.titleFont)
                .foregroundStyle(.secondary)
            if allChunks.isEmpty {
                Text("Go to Settings to index your photos, contacts, and calendar.")
                    .font(Theme.bodyFont)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconFor(_ type: MemoryChunk.SourceType) -> String {
        switch type {
        case .photo:        return "photo"
        case .contact:      return "person.circle"
        case .event:        return "calendar"
        case .reminder:     return "checklist"
        case .note:         return "note.text"
        case .conversation: return "bubble.left"
        case .email:        return "envelope"
        }
    }
}

// MARK: - Supporting types

private struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}

extension MemoryChunk.SourceType: CaseIterable {
    public static var allCases: [MemoryChunk.SourceType] = [
        .photo, .contact, .event, .reminder, .note, .conversation, .email
    ]
}

struct FilterChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption)
                Text(label).font(Theme.captionFont)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .animation(Theme.easeAnimation, value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
