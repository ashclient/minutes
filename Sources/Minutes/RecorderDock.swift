import AppKit
import SwiftUI

enum RecorderDockEdge: String { case left, right, top, bottom
    var vertical: Bool { self == .left || self == .right }
    var icon: String { switch self { case .left: return "chevron.right"; case .right: return "chevron.left"; case .top: return "chevron.down"; case .bottom: return "chevron.up" } }
}
@MainActor final class RecorderDockState: ObservableObject { @Published var edge: RecorderDockEdge? }
enum RecorderDockGeometry {
    static func screen(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        screens.max { area(frame.intersection($0)) < area(frame.intersection($1)) }
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
    static func edge(for frame: CGRect, screens: [CGRect]) -> RecorderDockEdge? {
        guard let screen = screen(for: frame, screens: screens) else { return nil }
        // A shared display boundary is not an outer edge. Let the user drag across it.
        let candidates: [(RecorderDockEdge, CGFloat, CGPoint)] = [
            (.left, screen.minX - frame.minX, CGPoint(x: frame.minX, y: frame.midY)),
            (.right, frame.maxX - screen.maxX, CGPoint(x: frame.maxX - 1, y: frame.midY)),
            (.top, frame.maxY - screen.maxY, CGPoint(x: frame.midX, y: frame.maxY - 1)),
            (.bottom, screen.minY - frame.minY, CGPoint(x: frame.midX, y: frame.minY))]
        return candidates.filter { candidate in candidate.1 > 10 && !screens.contains(where: { $0.contains(candidate.2) }) }.max { $0.1 < $1.1 }?.0
    }
    static func dockFrame(edge: RecorderDockEdge, previous: CGRect, visible: CGRect) -> CGRect {
        let size = CGSize(width: edge.vertical ? 24 : 44, height: edge.vertical ? 44 : 24)
        let x = min(max(previous.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(previous.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        switch edge {
        case .left: return CGRect(x: visible.minX, y: y, width: size.width, height: size.height)
        case .right: return CGRect(x: visible.maxX - size.width, y: y, width: size.width, height: size.height)
        case .top: return CGRect(x: x, y: visible.maxY - size.height, width: size.width, height: size.height)
        case .bottom: return CGRect(x: x, y: visible.minY, width: size.width, height: size.height)
        }
    }
    static func restored(_ frame: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8), y: min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8), width: frame.width, height: frame.height)
    }
}
