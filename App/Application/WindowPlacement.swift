import Foundation
import CoreGraphics

struct PlacementScreen: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

// Pure geometry keeps display selection consistent for both translator surfaces.
enum WindowPlacement {
    private static let fallback = PlacementScreen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))

    static func screen(near anchor: CGRect?, pointer: CGPoint, screens: [PlacementScreen]) -> PlacementScreen? {
        var best: PlacementScreen?
        var largestArea: CGFloat = 0
        if let anchor, !anchor.isNull, !anchor.isEmpty {
            for candidate in screens {
                let intersection = candidate.frame.intersection(anchor)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                if area > largestArea {
                    best = candidate
                    largestArea = area
                }
            }
        }
        return best ?? screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first
    }

    static func mainOrigin(
        size: CGSize, centered: Bool, rememberedOrigin: CGPoint?, pointer: CGPoint, screens: [PlacementScreen]
    ) -> CGPoint {
        if !centered, let origin = rememberedOrigin, origin.x.isFinite, origin.y.isFinite {
            let rememberedFrame = CGRect(origin: origin, size: size)
            let visible = (screen(near: rememberedFrame, pointer: pointer, screens: screens) ?? fallback).visibleFrame
            return CGPoint(
                x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
                y: max(visible.minY, min(origin.y, visible.maxY - size.height)))
        }
        let visible = (screen(near: nil, pointer: pointer, screens: screens) ?? fallback).visibleFrame
        return CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2)
    }
}

func selectionPanelOrigin(anchor: CGRect, visible: CGRect, size: CGSize) -> CGPoint {
    let margin: CGFloat = 12
    let right = anchor.maxX + margin
    let left = anchor.minX - size.width - margin
    let x = right + size.width <= visible.maxX - margin ? right : left
    return CGPoint(
        x: max(visible.minX + margin, min(x, visible.maxX - size.width - margin)),
        y: max(visible.minY + margin, min(anchor.maxY - size.height, visible.maxY - size.height - margin)))
}

// A result shown for a selection (the Edit with voice review): just under the
// selection's last line, else above its visible part, else beside it, on the
// screen that has it; never over the selection when there is room. `end` is the
// last character on screen; without it, the bottom of the visible selection is
// the line. With no selection on screen, it opens under the pointer.
func resultPanelOrigin(selection: CGRect?, end: CGRect?, pointer: CGPoint, visible: CGRect, size: CGSize) -> CGPoint {
    let margin: CGFloat = 12, gap: CGFloat = 10
    func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(visible.minX + margin, min(point.x, visible.maxX - size.width - margin)),
            y: max(visible.minY + margin, min(point.y, visible.maxY - size.height - margin)))
    }
    let shown = selection.map { $0.intersection(visible) }.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
    guard let area = shown ?? end else {
        return clamped(CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - 24))
    }
    let covered = area.union(end ?? area)
    // A spot is taken only if it is on screen as is and leaves the selection uncovered.
    func fits(_ point: CGPoint) -> Bool {
        let frame = CGRect(origin: point, size: size)
        return frame.minY >= visible.minY + margin && frame.maxY <= visible.maxY - margin
            && frame.minX >= visible.minX + margin - 0.5 && frame.maxX <= visible.maxX - margin + 0.5
            && !frame.intersects(covered)
    }
    // The line to sit under: the last character, else the visible part's last line.
    let line = end ?? CGRect(x: area.minX, y: area.minY, width: area.width, height: 1)
    // The panel's text (28 pt in) lines up with the selection's left edge.
    let x = clamped(CGPoint(x: area.minX - 28, y: 0)).x
    let below = CGPoint(x: x, y: line.minY - gap - size.height)
    if fits(below) { return below }
    let above = CGPoint(x: x, y: covered.maxY + gap)
    if fits(above) { return above }
    // A selection taller than the room around it: beside it, by the end line.
    let besideY = clamped(CGPoint(x: 0, y: line.midY - size.height / 2)).y
    let right = CGPoint(x: covered.maxX + gap, y: besideY)
    if fits(right) { return right }
    let left = CGPoint(x: covered.minX - gap - size.width, y: besideY)
    if fits(left) { return left }
    // No room anywhere: as low on the screen as it goes, near the end line.
    return clamped(CGPoint(x: line.minX, y: visible.minY + margin))
}
