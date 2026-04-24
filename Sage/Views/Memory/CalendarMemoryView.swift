import SwiftUI

struct CalendarMemoryView: View {
    let chunks: [MemoryChunk]
    let onChunkTap: (MemoryChunk) -> Void

    @State private var displayMonth: Date = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: Date())
    @State private var showYearPicker = false

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdaySymbols = ["M", "T", "W", "T", "F", "S", "S"]

    // MARK: - Precomputed chunk map

    /// key: "yyyy-MM-dd" → chunks whose sourceDate falls on that day
    private var chunksByDay: [String: [MemoryChunk]] {
        var map: [String: [MemoryChunk]] = [:]
        let fmt = dayKey(for:)
        for chunk in chunks {
            guard let date = chunk.sourceDate else { continue }
            let key = fmt(date)
            map[key, default: []].append(chunk)
        }
        return map
    }

    private func dayKey(for date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year!)-\(String(format: "%02d", c.month!))-\(String(format: "%02d", c.day!))"
    }

    // MARK: - Month grid data

    private var monthDays: [Date?] {
        let start = displayMonth
        guard let range = cal.range(of: .day, in: .month, for: start) else { return [] }

        // ISO weekday: Monday = 2, adjust to 0-indexed Monday-first
        let firstWeekday = (cal.component(.weekday, from: start) + 5) % 7 // Mon=0 … Sun=6
        var days: [Date?] = Array(repeating: nil, count: firstWeekday)

        for day in range {
            if let date = cal.date(byAdding: .day, value: day - 1, to: start) {
                days.append(date)
            }
        }
        // Pad to complete last row
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var selectedDayChunks: [MemoryChunk] {
        guard let day = selectedDay else { return [] }
        return chunksByDay[dayKey(for: day)] ?? []
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            monthNavigation
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            weekdayRow
                .padding(.horizontal, 8)

            Divider().padding(.vertical, 4)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCell(
                            date: date,
                            chunks: chunksByDay[dayKey(for: date)] ?? [],
                            isSelected: selectedDay.map { cal.isDate($0, inSameDayAs: date) } ?? false,
                            isToday: cal.isDateInToday(date)
                        )
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedDay = cal.isDate(selectedDay ?? .distantPast, inSameDayAs: date)
                                    ? nil : date
                            }
                        }
                    } else {
                        Color.clear.frame(height: 52)
                    }
                }
            }
            .padding(.horizontal, 8)

            Divider().padding(.top, 8)

            // Day detail
            if let day = selectedDay {
                dayDetailSection(day: day)
            } else {
                Spacer()
            }
        }
        .sheet(isPresented: $showYearPicker) {
            YearPickerSheet(current: displayMonth) { year in
                if let newDate = cal.date(
                    from: DateComponents(year: year, month: cal.component(.month, from: displayMonth), day: 1)
                ) { displayMonth = newDate }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Month navigation

    private var monthNavigation: some View {
        HStack {
            Button { navigate(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            Spacer()
            Button { showYearPicker = true } label: {
                VStack(spacing: 1) {
                    Text(displayMonth.formatted(.dateTime.month(.wide)))
                        .font(Theme.titleFont)
                    Text(displayMonth.formatted(.dateTime.year()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            Spacer()
            Button { navigate(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
        }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func navigate(_ months: Int) {
        if let next = cal.date(byAdding: .month, value: months, to: displayMonth) {
            withAnimation(.easeInOut(duration: 0.2)) {
                displayMonth = next
                selectedDay = nil
            }
        }
    }

    // MARK: - Day detail

    @ViewBuilder
    private func dayDetailSection(day: Date) -> some View {
        let chunks = selectedDayChunks
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(Theme.headlineFont)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Spacer()
                Text("\(chunks.count) item\(chunks.count == 1 ? "" : "s")")
                    .font(Theme.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 16)
            }

            if chunks.isEmpty {
                VStack {
                    Spacer(minLength: 20)
                    Text("Nothing indexed on this day")
                        .font(Theme.captionFont)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(chunks) { chunk in
                            MemoryChunkRow(chunk: chunk, onTap: { onChunkTap(chunk) })
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let chunks: [MemoryChunk]
    let isSelected: Bool
    let isToday: Bool

    private var typeColors: [Color] {
        var seen: [MemoryChunk.SourceType: Color] = [:]
        for c in chunks {
            if seen[c.sourceType] == nil {
                seen[c.sourceType] = typeColor(c.sourceType)
                if seen.count == 4 { break }
            }
        }
        return Array(seen.values)
    }

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(size: 14, weight: isToday ? .bold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? .white : (isToday ? Color.accentColor : .primary))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(isSelected ? Color.accentColor : Color.clear)
                )

            // Type dots
            HStack(spacing: 3) {
                ForEach(Array(typeColors.prefix(4).enumerated()), id: \.offset) { _, color in
                    Circle().fill(color).frame(width: 4, height: 4)
                }
            }
            .frame(height: 6)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(chunks.isEmpty ? Color.clear : Color(.secondarySystemBackground).opacity(0.6))
        )
    }

    private func typeColor(_ type: MemoryChunk.SourceType) -> Color {
        switch type {
        case .photo:        return .purple
        case .note:         return Theme.teal
        case .event:        return .red
        case .reminder:     return .orange
        case .contact:      return .blue
        case .conversation: return .green
        case .email:        return .cyan
        }
    }
}

// MARK: - Year picker

private struct YearPickerSheet: View {
    let current: Date
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    private let currentYear = Calendar.current.component(.year, from: Date())
    private var years: [Int] { Array((currentYear - 10)...(currentYear + 2)) }

    var body: some View {
        NavigationStack {
            List(years, id: \.self) { year in
                Button {
                    onSelect(year)
                    dismiss()
                } label: {
                    HStack {
                        Text(String(year))
                            .font(Theme.bodyFont)
                        Spacer()
                        if year == Calendar.current.component(.year, from: current) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Select Year")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Calendar helper

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}
