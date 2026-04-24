import SwiftUI

struct CalendarMemoryView: View {
    let chunks: [MemoryChunk]
    let onChunkTap: (MemoryChunk) -> Void

    @State private var displayMonth: Date = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var showYearPicker = false

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdayHeaders = ["M", "T", "W", "T", "F", "S", "S"]

    // MARK: - Precomputed chunk map

    /// "yyyy-MM-dd" → chunks whose sourceDate falls on that day
    private var chunksByDay: [String: [MemoryChunk]] {
        var map: [String: [MemoryChunk]] = [:]
        for chunk in chunks {
            guard let date = chunk.sourceDate else { continue }
            let key = dayKey(for: date)
            map[key, default: []].append(chunk)
        }
        return map
    }

    private func dayKey(for date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: - Month grid data

    private var monthDays: [Date?] {
        let start = displayMonth
        guard let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        // ISO weekday: Monday = 2 → 0-indexed Monday-first offset
        let firstWeekday = (cal.component(.weekday, from: start) + 5) % 7
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in range {
            if let date = cal.date(byAdding: .day, value: day - 1, to: start) {
                days.append(date)
            }
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: displayMonth)
    }

    // MARK: - Selected-day chunks

    private var selectedDayChunks: [MemoryChunk] {
        guard let day = selectedDay else { return [] }
        return chunksByDay[dayKey(for: day)] ?? []
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            monthNavBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Weekday column headers
            HStack(spacing: 0) {
                ForEach(Array(weekdayHeaders.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            // Day grid
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCell(
                            date: date,
                            chunks: chunksByDay[dayKey(for: date)] ?? [],
                            isToday: cal.isDateInToday(date),
                            isSelected: selectedDay.map { cal.isDate($0, inSameDayAs: date) } ?? false
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedDay = cal.isDate(selectedDay ?? .distantPast, inSameDayAs: date)
                                    ? nil : date
                            }
                        }
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
            .padding(.horizontal, 8)

            Divider().padding(.top, 8)

            // Selected-day detail list
            if let day = selectedDay, !selectedDayChunks.isEmpty {
                dayDetailList(for: day)
            } else if selectedDay != nil {
                Text("No memories on this day")
                    .font(Theme.captionFont)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .sheet(isPresented: $showYearPicker) {
            yearPickerSheet
                .presentationDetents([.medium])
        }
    }

    // MARK: - Month navigation bar

    private var monthNavBar: some View {
        HStack {
            Button {
                withAnimation { displayMonth = cal.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Button {
                showYearPicker = true
            } label: {
                Text(monthTitle)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                withAnimation { displayMonth = cal.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Day detail list

    private func dayDetailList(for day: Date) -> some View {
        let dayFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f
        }()

        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(dayFormatter.string(from: day))
                    .font(Theme.captionFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ForEach(selectedDayChunks) { chunk in
                    MemoryChunkRow(chunk: chunk, onTap: { onChunkTap(chunk) })
                        .padding(.horizontal, 16)
                }

                Spacer(minLength: 20)
            }
        }
    }

    // MARK: - Year picker sheet

    private var yearPickerSheet: some View {
        let currentYear = cal.component(.year, from: Date())
        let years = Array((currentYear - 10)...(currentYear + 2))
        let monthFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "MMMM"; return f
        }()
        let months = (1...12).compactMap { m -> (Int, String)? in
            var comps = DateComponents(); comps.year = 2000; comps.month = m; comps.day = 1
            guard let date = cal.date(from: comps) else { return nil }
            return (m, monthFormatter.string(from: date))
        }

        return NavigationStack {
            List {
                ForEach(years.reversed(), id: \.self) { year in
                    Section(String(year)) {
                        ForEach(months, id: \.0) { month, name in
                            Button(name) {
                                var comps = DateComponents()
                                comps.year = year; comps.month = month; comps.day = 1
                                if let date = cal.date(from: comps) {
                                    displayMonth = date
                                }
                                showYearPicker = false
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Jump to Month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showYearPicker = false }
                }
            }
        }
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let chunks: [MemoryChunk]
    let isToday: Bool
    let isSelected: Bool

    private static let dayNumberFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()

    /// Up to 4 distinct source types present on this day
    private var dotTypes: [MemoryChunk.SourceType] {
        var seen: Set<MemoryChunk.SourceType> = []
        var result: [MemoryChunk.SourceType] = []
        for chunk in chunks {
            if seen.insert(chunk.sourceType).inserted {
                result.append(chunk.sourceType)
            }
            if result.count == 4 { break }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 30, height: 30)
                } else if isToday {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                }

                Text(Self.dayNumberFormatter.string(from: date))
                    .font(.system(size: 14, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : (isToday ? Color.accentColor : .primary))
            }
            .frame(height: 30)

            // Type-coloured dots
            HStack(spacing: 2) {
                ForEach(dotTypes, id: \.rawValue) { type in
                    Circle()
                        .fill(dotColor(for: type))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(height: 6)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    private func dotColor(for type: MemoryChunk.SourceType) -> Color {
        switch type {
        case .photo:        return .purple
        case .contact:      return .blue
        case .event:        return .red
        case .reminder:     return .orange
        case .note:         return .yellow
        case .conversation: return .green
        case .email:        return .teal
        }
    }
}

// MARK: - Calendar extension

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}
