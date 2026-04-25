import SwiftUI

// MARK: - CalendarMemoryView

struct CalendarMemoryView: View {
    let chunks: [MemoryChunk]
    let onChunkTap: (MemoryChunk) -> Void

    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDayKey: String? = nil
    @State private var showYearPicker = false

    private let cal = Calendar.current
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f
    }()

    // MARK: - Data helpers

    private var chunksByDay: [String: [MemoryChunk]] {
        var result: [String: [MemoryChunk]] = [:]
        for chunk in chunks {
            let date = chunk.sourceDate ?? chunk.updatedAt
            let key = Self.keyFormatter.string(from: date)
            result[key, default: []].append(chunk)
        }
        return result
    }

    /// All date slots for the displayed month grid (nil = empty leading/trailing pad)
    private var gridDays: [Date?] {
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: displayedMonth)),
              let dayCount = cal.range(of: .day, in: .month, for: monthStart)?.count else { return [] }

        let firstWeekday = cal.component(.weekday, from: monthStart)
        let leadingBlanks = (firstWeekday - cal.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for i in 0..<dayCount {
            if let d = cal.date(byAdding: .day, value: i, to: monthStart) {
                days.append(d)
            }
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var weekdaySymbols: [String] {
        var symbols = cal.veryShortStandaloneWeekdaySymbols // S M T W T F S
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var selectedDayChunks: [MemoryChunk] {
        guard let key = selectedDayKey else { return [] }
        return (chunksByDay[key] ?? []).sorted {
            ($0.sourceDate ?? $0.updatedAt) > ($1.sourceDate ?? $1.updatedAt)
        }
    }

    private var selectedDayLabel: String {
        guard let key = selectedDayKey,
              let date = Self.keyFormatter.date(from: key) else { return "" }
        return Self.dayHeaderFormatter.string(from: date)
    }

    // MARK: - Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                monthHeader
                weekdayHeader
                monthGrid
                    .padding(.horizontal, 6)
                    // Horizontal swipe on the grid pages between months. We
                    // attach the gesture to the grid rather than the whole
                    // ScrollView so vertical scrolling to the day-detail
                    // panel still works smoothly.
                    .gesture(monthSwipeGesture)
                    .id(displayedMonth)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))

                // Selected-day detail — slides in below the grid
                if !selectedDayChunks.isEmpty {
                    dayDetailSection
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer(minLength: 40)
            }
        }
        .sheet(isPresented: $showYearPicker) {
            YearMonthPickerSheet(displayedMonth: $displayedMonth)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .animation(.easeInOut(duration: 0.25), value: selectedDayKey)
        .animation(.easeInOut(duration: 0.25), value: displayedMonth)
    }

    /// Drag gesture that pages the calendar by month. We require a meaningful
    /// horizontal distance and a horizontal-dominant motion so it doesn't
    /// fight with vertical scroll.
    private var monthSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                advance(by: dx < 0 ? 1 : -1)
            }
    }

    // MARK: - Month header

    private var monthHeader: some View {
        HStack(spacing: 0) {
            navButton(icon: "chevron.left") {
                advance(by: -1)
            }

            Button {
                showYearPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(Self.monthFormatter.string(from: displayedMonth))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            navButton(icon: "chevron.right") {
                advance(by: 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private func navButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    // MARK: - Weekday header row

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            // Index-keyed because `veryShortStandaloneWeekdaySymbols` repeats
            // letters (S/M/T/W/T/F/S — both T's and both S's collide). Using
            // `id: \.self` here would give duplicate IDs and SwiftUI would
            // log "undefined results" plus mis-recycle the Text views.
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, sym in
                Text(sym)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        let days = gridDays
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
            spacing: 2
        ) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                if let date {
                    let key = Self.keyFormatter.string(from: date)
                    let dayChunks = chunksByDay[key] ?? []
                    DayCell(
                        date: date,
                        chunks: dayChunks,
                        isToday: cal.isDateInToday(date),
                        isSelected: selectedDayKey == key,
                        isCurrentMonth: cal.isDate(date, equalTo: displayedMonth, toGranularity: .month)
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDayKey = (selectedDayKey == key) ? nil : key
                        }
                    }
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                }
            }
        }
    }

    // MARK: - Day detail

    private var dayDetailSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text(selectedDayLabel)
                    .font(.system(.subheadline, weight: .semibold))
                Spacer()
                Text("\(selectedDayChunks.count) item\(selectedDayChunks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation { selectedDayKey = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 16)

            // Type summary bar
            typeSummaryBar(for: selectedDayChunks)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()
                .padding(.horizontal, 16)

            // Chunk rows
            ForEach(selectedDayChunks) { chunk in
                MemoryChunkRow(chunk: chunk, onTap: { onChunkTap(chunk) })
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                Divider()
                    .padding(.horizontal, 16)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private func typeSummaryBar(for chunks: [MemoryChunk]) -> some View {
        let grouped = Dictionary(grouping: chunks, by: \.sourceType)
        let types = MemoryChunk.SourceType.allCases.filter { grouped[$0] != nil }
        return HStack(spacing: 12) {
            ForEach(types, id: \.self) { type in
                HStack(spacing: 4) {
                    Circle()
                        .fill(type.calendarColor)
                        .frame(width: 8, height: 8)
                    Text("\(grouped[type]!.count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                    Text(type.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private func advance(by months: Int) {
        withAnimation(.easeInOut(duration: 0.3)) {
            displayedMonth = cal.date(byAdding: .month, value: months, to: displayedMonth) ?? displayedMonth
            selectedDayKey = nil
        }
    }
}

// MARK: - DayCell

private struct DayCell: View {
    let date: Date
    let chunks: [MemoryChunk]
    let isToday: Bool
    let isSelected: Bool
    let isCurrentMonth: Bool
    let onTap: () -> Void

    private let cal = Calendar.current

    private var dayNumber: Int { cal.component(.day, from: date) }
    private var hasContent: Bool { !chunks.isEmpty }

    /// Up to 4 distinct source-type colors for the dot row
    private var dotColors: [Color] {
        let types = Array(Set(chunks.map(\.sourceType))).sorted { $0.rawValue < $1.rawValue }
        return types.prefix(4).map(\.calendarColor)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                // Day number circle
                ZStack {
                    if isToday {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 28, height: 28)
                    } else if isSelected && hasContent {
                        Circle()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: 28, height: 28)
                    }
                    Text("\(dayNumber)")
                        .font(.system(size: 13, weight: isToday || hasContent ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.white : isCurrentMonth ? Color.primary : Color.secondary.opacity(0.4))
                }

                // Type dots
                if hasContent {
                    HStack(spacing: 2) {
                        ForEach(Array(dotColors.enumerated()), id: \.offset) { _, color in
                            Circle()
                                .fill(color)
                                .frame(width: 5, height: 5)
                        }
                    }

                    // Item count
                    Text("\(chunks.count)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    // Keep height consistent
                    Spacer().frame(height: 5)
                    Spacer().frame(height: 11)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                isSelected && hasContent
                    ? Color.accentColor.opacity(0.06)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(isCurrentMonth ? 1 : 0.35)
        .disabled(!hasContent)
    }
}

// MARK: - Year / Month Picker Sheet

struct YearMonthPickerSheet: View {
    @Binding var displayedMonth: Date
    @Environment(\.dismiss) private var dismiss

    private let cal = Calendar.current
    @State private var selectedYear: Int

    private let currentYear = Calendar.current.component(.year, from: Date())
    private let years: [Int]

    init(displayedMonth: Binding<Date>) {
        _displayedMonth = displayedMonth
        let y = Calendar.current.component(.year, from: displayedMonth.wrappedValue)
        _selectedYear = State(initialValue: y)
        years = Array((y - 10)...(y + 5))
    }

    private var months: [Date] {
        (0..<12).compactMap { m in
            cal.date(from: DateComponents(year: selectedYear, month: m + 1, day: 1))
        }
    }

    private static let shortMonth: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM"; return f
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Year picker row
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(years, id: \.self) { year in
                                Button {
                                    withAnimation { selectedYear = year }
                                } label: {
                                    Text("\(year)")
                                        .font(.system(.subheadline, weight: selectedYear == year ? .bold : .regular))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(selectedYear == year ? Color.accentColor : Color(.tertiarySystemFill))
                                        .foregroundStyle(selectedYear == year ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .id(year)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onAppear {
                        proxy.scrollTo(selectedYear, anchor: .center)
                    }
                    .onChange(of: selectedYear) { _, y in
                        withAnimation { proxy.scrollTo(y, anchor: .center) }
                    }
                }

                Divider()

                // Month grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(months, id: \.self) { month in
                        let isDisplayed = cal.isDate(month, equalTo: displayedMonth, toGranularity: .month)
                        let isCurrentMonth = cal.isDate(month, equalTo: Date(), toGranularity: .month)

                        Button {
                            displayedMonth = Calendar.current.startOfMonth(for: month)
                            dismiss()
                        } label: {
                            Text(Self.shortMonth.string(from: month))
                                .font(.system(.body, weight: isDisplayed ? .bold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(isDisplayed ? Color.accentColor : isCurrentMonth ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill))
                                .foregroundStyle(isDisplayed ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Jump to Month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Today") {
                        displayedMonth = Calendar.current.startOfMonth(for: Date())
                        dismiss()
                    }
                }
            }
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

// MARK: - SourceType calendar colors

extension MemoryChunk.SourceType {
    var calendarColor: Color {
        switch self {
        case .photo:        return .purple
        case .note:         return Color(red: 0.95, green: 0.7, blue: 0.1)  // amber
        case .event:        return .red
        case .reminder:     return .orange
        case .contact:      return .blue
        case .conversation: return .teal
        case .email:        return .green
        }
    }
}
