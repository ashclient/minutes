import SwiftUI

struct CalendarMeeting: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
    let color: Color
    let eventURL: URL?
}
enum GoogleCalendarEvent {
    static func date(_ value: [String: Any]) -> Date? {
        if let raw = value["dateTime"] as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: raw)
        }
        guard let raw = value["date"] as? String else { return nil }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = .current
        return formatter.date(from: raw)
    }
    static func meeting(_ json: [String: Any], calendarID: String, name: String) -> CalendarMeeting? {
        guard json["status"] as? String != "cancelled", let id = json["id"] as? String,
              let begin = json["start"] as? [String: Any], let finish = json["end"] as? [String: Any],
              let start = date(begin), let end = date(finish) else { return nil }
        if let attendees = json["attendees"] as? [[String: Any]], attendees.contains(where: { $0["self"] as? Bool == true && $0["responseStatus"] as? String == "declined" }) { return nil }
        let title = json["summary"] as? String ?? "Untitled event"
        return CalendarMeeting(id: "google:" + calendarID + ":" + id, title: title.isEmpty ? "Untitled event" : title, start: start, end: end, calendar: name, color: .blue, eventURL: (json["htmlLink"] as? String).flatMap(URL.init(string:)))
    }
}
@MainActor final class CalendarMeetings: ObservableObject {
    @Published private(set) var events: [CalendarMeeting] = []
    @Published private(set) var calendars: [(id: String, title: String)] = []
    @Published private(set) var authorized = false
    @Published private(set) var configured = false
    @Published private(set) var signingIn = false
    @Published private(set) var refreshing = false
    @Published var message = "Connect Google Calendar to see upcoming meetings."
    private let account = GoogleCalendarAccount()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    init() {
        configured = account.configured; authorized = account.connected
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        if authorized { refresh() }
    }
    func importClient(_ data: Data) throws { try account.importConfig(data); configured = true; authorized = account.connected; message = "Google sign-in is ready. Click Connect Google." }
    func connect() async {
        guard !signingIn else { return }; signingIn = true; defer { signingIn = false }
        do { try await account.connect(); authorized = true; refresh() }
        catch is CancellationError { message = "Google sign-in cancelled." }
        catch { message = error.localizedDescription }
    }
    func cancelSignIn() { account.cancelSignIn() }
    func disconnect() {
        do { try account.disconnect(); refreshTask?.cancel(); refreshTask = nil; authorized = false; events = []; calendars = []; message = "Google Calendar disconnected." }
        catch { message = error.localizedDescription }
    }
    func refresh() {
        guard authorized else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            refreshing = true; defer { refreshing = false }
            do {
                let found = try await account.list("users/me/calendarList")
                calendars = found.compactMap { item in guard let id = item["id"] as? String else { return nil }; return (id: id, title: item["summary"] as? String ?? id) }
                let hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenGoogleCalendars") ?? [])
                let selected = calendars.filter { !hidden.contains($0.id) }
                let now = Date(); let formatter = ISO8601DateFormatter()
                var results: [CalendarMeeting] = []
                for item in selected {
                    try Task.checkCancellation()
                    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?%#"))
                    let path = "calendars/" + (item.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "/events"
                    let items = try await account.list(path, query: [URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"), URLQueryItem(name: "timeMin", value: formatter.string(from: now.addingTimeInterval(-3 * 3600))), URLQueryItem(name: "timeMax", value: formatter.string(from: now.addingTimeInterval(14 * 86400))), URLQueryItem(name: "maxResults", value: "250")])
                    results += items.compactMap { GoogleCalendarEvent.meeting($0, calendarID: item.id, name: item.title) }.filter { $0.end > now }
                }
                try Task.checkCancellation()
                events = results.sorted { $0.start < $1.start }
                message = selected.isEmpty ? "Choose a Google calendar below." : events.isEmpty ? "No upcoming Google events in the next two weeks." : "Connected · \(events.count) upcoming events"
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
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
