//
//  ClickyGesturePerformer.swift
//  leanring-buddy
//
//  Lets Clicky physically perform simple input gestures — right now, a gentle
//  scroll at a target location — so a walkthrough step like "scroll the left
//  sidebar" can be demonstrated, not just described. Uses CoreGraphics synthetic
//  events, which require Accessibility permission (the app already needs it for
//  the global push-to-talk shortcut).
//

import AppKit
import CoreGraphics

/// The direction Clicky should scroll when demonstrating a step.
enum ClickyScrollDirection: String {
    case up
    case down
    case left
    case right
}

enum ClickyGesturePerformer {

    /// Performs a gentle scroll at the given global AppKit point. Moves the real
    /// cursor to the point first (scroll-wheel events are delivered to whatever
    /// view is under the cursor), then posts several small wheel ticks so the
    /// motion looks smooth and deliberate rather than a single jarring jump.
    ///
    /// `appKitPoint` is in global AppKit coordinates (origin at the bottom-left
    /// of the main screen, y increasing upward) — the same space the pointing
    /// pipeline produces. We convert it to CoreGraphics' global space (origin at
    /// the top-left of the main screen, y increasing downward) for the warp.
    @MainActor
    static func performScroll(
        atGlobalAppKitPoint appKitPoint: CGPoint,
        direction: ClickyScrollDirection
    ) async {
        guard let mainScreen = NSScreen.screens.first else { return }

        let coreGraphicsPoint = CGPoint(
            x: appKitPoint.x,
            y: mainScreen.frame.maxY - appKitPoint.y
        )
        CGWarpMouseCursorPosition(coreGraphicsPoint)

        // A handful of small ticks ~24ms apart reads as one smooth gesture.
        let tickCount = 8
        for _ in 0..<tickCount {
            let (verticalDelta, horizontalDelta) = scrollDeltas(for: direction)
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(verticalDelta),
                wheel2: Int32(horizontalDelta),
                wheel3: 0
            ) {
                scrollEvent.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 24_000_000)
        }
    }

    /// The per-tick (vertical, horizontal) pixel deltas for a direction.
    /// On macOS scroll-wheel events, a positive `wheel1` scrolls the content
    /// view up (revealing content above), so "down" uses a negative delta.
    private static func scrollDeltas(for direction: ClickyScrollDirection) -> (vertical: Int, horizontal: Int) {
        let magnitude = 26
        switch direction {
        case .up: return (magnitude, 0)
        case .down: return (-magnitude, 0)
        case .left: return (0, magnitude)
        case .right: return (0, -magnitude)
        }
    }

    /// Parses an optional `[SCROLL:up|down|left|right]` tag from a Claude
    /// response. Returns nil when no valid scroll tag is present.
    static func parseScrollDirection(from responseText: String) -> ClickyScrollDirection? {
        let pattern = #"\[SCROLL:\s*(up|down|left|right)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let directionRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }
        return ClickyScrollDirection(rawValue: String(responseText[directionRange]).lowercased())
    }
}
