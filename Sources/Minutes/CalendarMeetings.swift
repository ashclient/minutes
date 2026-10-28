import SwiftUI
import EventKit

struct CalendarMeeting: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
    let color: Color
    let eventURL: URL?
}
@MainActor final class CalendarMeetings: ObservableObject {
    @Published private(set) var events: [CalendarMeeting] = []
    @Published private(set) var calendars: [(id: String, title: String)] = []
    @Published private(set) var authorized = false
    @Published var message = "Connect the calendars you use in Notion Calendar."
    private let eventStore = EKEventStore()
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }
    func connect() async {
        do {
            guard try await eventStore.requestFullAccessToEvents() else { message = "Allow Calendar access in System Settings → Privacy & Security → Calendars."; return }
            UserDefaults.standard.set(true, forKey: "calendarEnabled"); refresh()
        } catch { message = error.localizedDescription }
    }
    func disconnect() {
        UserDefaults.standard.set(false, forKey: "calendarEnabled"); authorized = false; events = []; calendars = []
    }
    func refresh() {
        guard UserDefaults.standard.bool(forKey: "calendarEnabled"), EKEventStore.authorizationStatus(for: .event) == .fullAccess else { authorized = false; events = []; return }
        authorized = true
        let available = eventStore.calendars(for: .event)
        calendars = available.map { (id: $0.calendarIdentifier, title: $0.title) }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
        let selected = available.filter { !hidden.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { events = []; message = "Choose a calendar in Connections, or add your account in macOS Calendar → Settings → Accounts."; return }
        let now = Date()
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(14 * 86400), calendars: selected)
        let found = eventStore.events(matching: predicate).filter { $0.endDate > now && $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
        var seen = Set<String>()
        events = found.compactMap { event in
            let key = Self.key(identifier: event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier, calendar: event.calendar.calendarIdentifier, start: event.startDate)
            guard seen.insert(key).inserted else { return nil }
            return CalendarMeeting(id: key, title: event.title?.isEmpty == false ? event.title : "Untitled event", start: event.startDate, end: event.endDate, calendar: event.calendar.title, color: Color(cgColor: event.calendar.cgColor), eventURL: event.url)
        }
        message = events.isEmpty ? "No upcoming events in the next two weeks." : "\(events.count) upcoming events"
    }
    nonisolated static func key(identifier: String, calendar: String, start: Date) -> String { calendar + ":" + identifier + ":" + String(Int(start.timeIntervalSince1970)) }
}
extension Store {
    @discardableResult func open(_ event: CalendarMeeting) -> UUID? {
        if let existing = meetings.first(where: { $0.calendarEventKey == event.id }) {
            update(existing.id) { $0.trashed = false; $0.eventStart = event.start; $0.eventEnd = event.end }
            selectedID = existing.id; filter = "All meetings"; query = ""; return existing.id
        }
        guard let id = create() else { return nil }
        update(id) { $0.title = event.title; $0.calendarEventKey = event.id; $0.eventStart = event.start; $0.eventEnd = event.end; $0.eventCalendar = event.calendar }
        return id
    }
}
