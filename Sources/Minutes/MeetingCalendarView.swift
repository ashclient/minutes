import SwiftUI

enum CalendarLayout {
    static func periodDays(_ date: Date, week: Bool, calendar: Calendar = .current) -> [Date] {
        let start = week ? (calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)) : calendar.startOfDay(for: date)
        return (0..<(week ? 7 : 1)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    static func gridDates(for date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let offset = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -offset, to: month.start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    static func contains(_ event: CalendarMeeting, day: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return event.start < end && event.end > start
    }
}
enum CalendarMode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", agenda = "Agenda" }

@MainActor struct MeetingCalendarView: View {
    @EnvironmentObject var calendar: CalendarMeetings
    @EnvironmentObject var store: Store
    let open: (CalendarMeeting) -> Void
    @AppStorage("calendarLayout") private var mode: CalendarMode = .week
    @State private var month = Date()
    @State private var selected = Date()
    @State private var filter = "All calendars"
    private var visible: [CalendarMeeting] { calendar.monthEvents.filter { filter == "All calendars" || $0.calendar == filter } }
    private var dates: [Date] { CalendarLayout.gridDates(for: month) }
    private var weekdays: [String] { let c = Calendar.current; let names = c.shortStandaloneWeekdaySymbols; return (0..<7).map { names[($0 + c.firstWeekday - 1) % 7] } }
    var body: some View {
        GeometryReader { geometry in ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 25, weight: .semibold))
                    Spacer()
                    Picker("Layout", selection: $mode) { ForEach(CalendarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 110)
                    if calendar.monthLoading { ProgressView().controlSize(.small) }
                    Button("Today") { month = Date(); selected = Date(); calendar.loadMonth(month) }
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("Previous period")
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.help("Next period")
                    Button { calendar.loadMonth(month) } label: { Image(systemName: "arrow.clockwise") }.help("Refresh calendar")
                }
                HStack {
                    Text("Click an event to open its meeting note.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Calendar", selection: $filter) { Text("All calendars").tag("All calendars"); ForEach(Array(Set(calendar.monthEvents.map(\.calendar))).sorted(), id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(maxWidth: 200)
                }
                if mode == .month {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in Text(name).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 10) } }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                        ForEach(dates, id: \.self) { date in day(date, height: max(64, (geometry.size.height - 180) / 6)) }
                    }.background(Color.primary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                } else if mode == .day || mode == .week {
                    CalendarTimeline(days: CalendarLayout.periodDays(selected, week: mode == .week), events: visible, open: open).frame(height: max(400, geometry.size.height - 160))
                }
                if !calendar.monthMessage.isEmpty { Text(calendar.monthMessage).font(.callout).foregroundStyle(.secondary) }
                if mode == .month || mode == .agenda {
                Text(mode == .agenda ? "Schedule" : selected.formatted(date: .complete, time: .omitted)).font(.headline)
                let agenda = visible.filter { mode == .agenda || CalendarLayout.contains($0, day: selected) }
                if agenda.isEmpty { Text("No events on this day.").font(.callout).foregroundStyle(.secondary) }
                ForEach(agenda) { event in
                    Button { open(event) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4)
                            VStack(alignment: .leading, spacing: 5) { Text(event.title).fontWeight(.medium); Text(eventSubtitle(event)).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if store.meetings.contains(where: { $0.calendarEventKey == event.id && !$0.trashed }) { Image(systemName: "doc.text").help("Meeting note exists") }
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }.padding(13).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(QuietButtonStyle())
                }
                }
            }.padding(24)
        } }.onAppear {
            if let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--calendar-layout=") }), let value = CalendarMode(rawValue: String(raw.dropFirst("--calendar-layout=".count))) { mode = value }
            calendar.loadMonth(month)
        }
    }
    private func eventSubtitle(_ event: CalendarMeeting) -> String {
        let date = mode == .agenda ? event.start.formatted(.dateTime.weekday(.abbreviated).month().day()) + " · " : ""
        let time = event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened)
        return date + event.calendar + " · " + time
    }
    private func move(_ amount: Int) { if let next = Calendar.current.date(byAdding: mode == .month || mode == .agenda ? .month : .day, value: mode == .week ? amount * 7 : amount, to: selected) { month = next; selected = next; calendar.loadMonth(next) } }
    private func day(_ date: Date, height: CGFloat) -> some View {
        let events = visible.filter { CalendarLayout.contains($0, day: date) }
        let current = Calendar.current.isDate(date, equalTo: month, toGranularity: .month)
        let chosen = Calendar.current.isDate(date, inSameDayAs: selected)
        return VStack(alignment: .leading, spacing: 4) {
            Button { selected = date } label: {
                Text(date.formatted(.dateTime.day())).font(.system(size: 11, weight: Calendar.current.isDateInToday(date) ? .bold : .regular)).foregroundStyle(current ? Color.primary : Color.secondary.opacity(0.6)).frame(width: 22, height: 22).background(Calendar.current.isDateInToday(date) ? Color.accentColor.opacity(0.15) : Color.clear, in: Circle()).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(QuietButtonStyle())
            ForEach(Array(events.prefix(2))) { event in
                Button { open(event) } label: { Text((event.allDay ? "" : event.start.formatted(.dateTime.hour().minute()) + " ") + event.title).font(.system(size: 9)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(3).background(event.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3)) }.buttonStyle(QuietButtonStyle()).help(event.title)
            }
            if events.count > 2 { Button("+\(events.count - 2) more") { selected = date }.font(.system(size: 9)).buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(6).frame(maxWidth: .infinity).frame(height: height).background(chosen ? Color.accentColor.opacity(0.06) : Color(nsColor: .textBackgroundColor)).contentShape(Rectangle()).onTapGesture { selected = date }
    }
}
