import SwiftUI

struct CalendarEventPosition: Identifiable {
    let event: CalendarMeeting
    let lane: Int
    var lanes: Int
    var id: String { event.id }
}
enum CalendarTimelineLayout {
    static func positions(_ events: [CalendarMeeting]) -> [CalendarEventPosition] {
        let sorted = events.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var result: [CalendarEventPosition] = [], ends: [Date] = [], groupStart = 0, groupEnd = Date.distantPast
        func finish() { let count = max(1, ends.count); for i in groupStart..<result.count { result[i].lanes = count } }
        for event in sorted {
            if event.start >= groupEnd { finish(); groupStart = result.count; ends = []; groupEnd = event.end }
            let lane = ends.firstIndex(where: { $0 <= event.start }) ?? ends.count
            if lane == ends.count { ends.append(event.end) } else { ends[lane] = event.end }
            result.append(CalendarEventPosition(event: event, lane: lane, lanes: 1)); groupEnd = max(groupEnd, event.end)
        }
        finish(); return result
    }
    static func minute(_ date: Date, day: Date) -> Double {
        if date <= Calendar.current.startOfDay(for: day) { return 0 }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))!
        if date >= end { return 1440 }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}
struct CalendarTimeline: View {
    let days: [Date]
    let events: [CalendarMeeting]
    let open: (CalendarMeeting) -> Void
    private let hour: CGFloat = 56
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(TimeZone.current.abbreviation() ?? "Time").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 48)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day())).font(.system(size: 20, weight: .medium)).frame(width: 32, height: 32).foregroundStyle(Calendar.current.isDateInToday(day) ? Color.accentColor : Color.primary)
                        ForEach(events.filter { $0.allDay && CalendarLayout.contains($0, day: day) }) { event in
                            Button { open(event) } label: { Text(event.title).font(.system(size: 10)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(3).background(event.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 3)) }.buttonStyle(QuietButtonStyle()).help(event.title)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) { ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 48, height: hour, alignment: .top).id("hour-\(h)") } }
                        ForEach(days, id: \.self) { day in column(day) }
                    }.frame(height: hour * 24)
                }.onAppear { proxy.scrollTo("hour-8", anchor: .top) }
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private func column(_ day: Date) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Path { path in
                    for h in 0...24 { path.move(to: CGPoint(x: 0, y: CGFloat(h) * hour)); path.addLine(to: CGPoint(x: geometry.size.width, y: CGFloat(h) * hour)) }
                    path.move(to: .zero); path.addLine(to: CGPoint(x: 0, y: hour * 24))
                }.stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                ForEach(CalendarTimelineLayout.positions(events.filter { !$0.allDay && CalendarLayout.contains($0, day: day) })) { item in
                    let start = CalendarTimelineLayout.minute(item.event.start, day: day)
                    let end = CalendarTimelineLayout.minute(item.event.end, day: day)
                    let width = max(12, geometry.size.width / CGFloat(item.lanes) - 4)
                    Button { open(item.event) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.event.title).font(.system(size: 11, weight: .medium)).lineLimit(3)
                            Text(item.event.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.padding(5).frame(width: width, height: max(24, CGFloat(end - start) / 60 * hour - 2), alignment: .topLeading).background(item.event.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5)).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(item.event.color).frame(width: 2) }.clipped()
                    }.buttonStyle(SurfaceButtonStyle(radius: 5)).help(item.event.title + " · " + item.event.calendar).offset(x: CGFloat(item.lane) * geometry.size.width / CGFloat(item.lanes) + 2, y: CGFloat(start) / 60 * hour)
                }
                if Calendar.current.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Rectangle().fill(.red.opacity(0.7)).frame(height: 1).offset(y: CGFloat(CalendarTimelineLayout.minute(context.date, day: day)) / 60 * hour).allowsHitTesting(false)
                    }
                }
            }
        }.frame(maxWidth: .infinity).frame(height: hour * 24)
    }
}
