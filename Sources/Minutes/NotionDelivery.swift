import Foundation

enum NotionDeliveryMode: String, CaseIterable, Identifiable {
    case local, newPage, linked, existing
    var id: String { rawValue }
    var title: String { switch self { case .local: return "Only on this Mac"; case .newPage: return "Create a new Notion page"; case .linked: return "Update this meeting’s linked page"; case .existing: return "Add to an existing Notion page" } }
}
enum NotionDelivery {
    static func apply(mode: NotionDeliveryMode, page: NotionPageChoice?, to meeting: inout Meeting) {
        meeting.notionDeliveryRevision = UUID()
        meeting.notionSyncEnabled = mode != .local
        guard mode != .local else { return }
        if mode == .newPage || (mode == .existing && page?.id != meeting.notionPageID) {
            // Leave any old page untouched; start ownership tracking for the chosen destination.
            meeting.notionPageID = nil; meeting.notionURL = nil; meeting.notionBlockID = nil; meeting.notionBlockIDs = nil
            meeting.notionParentKind = nil; meeting.notionParentID = nil; meeting.notionSyncedAt = nil
        }
        if mode == .existing, let page {
            meeting.notionPageID = page.id; meeting.notionURL = page.url
            meeting.notionParentKind = "existing"; meeting.notionParentID = page.id
        }
        meeting.notionNeedsSync = true; meeting.notionError = nil
    }
}
extension Meeting {
    func shouldSync(automatic: Bool) -> Bool { notionSyncEnabled ?? automatic }
}
