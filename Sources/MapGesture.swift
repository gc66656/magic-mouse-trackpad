import CoreGraphics
import Foundation

/// Classifies a pair of contacts and filters the centroid used for scrolling.
struct MapGesture {
    enum Kind: Int64 { case scroll = 6, magnify = 8, rotate = 5 }

    private struct Geometry {
        let center: CGPoint
        let vector: CGPoint
        var distance: Double { hypot(vector.x, vector.y) }
        var angle: Double { atan2(vector.y, vector.x) }
    }

    private var origin: Geometry?
    private var previous: Geometry?
    private var firstID: Int32?
    private var secondID: Int32?
    private(set) var kind: Kind?
    private(set) var scrollDelta = CGPoint.zero
    private var scrollCenter = CGPoint.zero

    func tracks(_ touch: MTTouch) -> Bool {
        firstID == touch.identifier || secondID == touch.identifier
    }

    func tracks(_ a: MTTouch, _ b: MTTouch) -> Bool {
        firstID == min(a.identifier, b.identifier) && secondID == max(a.identifier, b.identifier)
    }

    mutating func update(_ a: MTTouch, _ b: MTTouch, rebaseScroll: Bool = false) -> Double {
        scrollDelta = .zero
        let (first, second) = a.identifier < b.identifier ? (a, b) : (b, a)
        // The surface is narrower across the mouse than along its length.
        let x = Double(first.normalized.position.x) * 0.72
        let y = Double(first.normalized.position.y)
        let u = Double(second.normalized.position.x) * 0.72
        let v = Double(second.normalized.position.y)
        let now = Geometry(
            center: CGPoint(x: (x + u) / 2, y: (y + v) / 2),
            vector: CGPoint(x: u - x, y: v - y)
        )
        guard let origin, let previous,
              firstID == first.identifier, secondID == second.identifier else {
            self.origin = now
            self.previous = now
            firstID = first.identifier
            secondID = second.identifier
            return 0
        }
        self.previous = now
        if kind == nil {
            let dx = now.center.x - origin.center.x
            let dy = now.center.y - origin.center.y
            let travel = hypot(dx, dy)
            let pinch = abs(now.distance - origin.distance)
            let turn = abs(Self.angleDelta(now.angle, origin.angle))
            let turnTravel = turn * min(now.distance, origin.distance) / 2
            let canTransform = min(now.distance, origin.distance) >= 0.12
            if canTransform, pinch >= 0.041, pinch >= travel * 2.4, pinch > turnTravel * 1.75 {
                kind = .magnify
            } else if canTransform, turn >= 0.24, turnTravel >= 0.023,
                      turnTravel >= travel * 1.25, turnTravel > pinch * 0.95 {
                kind = .rotate
            } else if travel >= 0.008, travel > pinch * 0.70, travel > turnTravel * 1.10 {
                // A short stroke can scroll when both fingertips advance in the same direction.
                // This rejects a pivot around a stationary finger at the lower threshold.
                let vectorDX = now.vector.x - origin.vector.x
                let vectorDY = now.vector.y - origin.vector.y
                let lessTravel = travel - abs(dx * vectorDX + dy * vectorDY) / (2 * travel)
                if lessTravel >= 0.002 {
                    kind = .scroll
                    scrollCenter = now.center
                    scrollDelta = CGPoint(x: dx, y: dy)
                }
            }
            // Consume the motion used to establish intent.
            return 0
        }
        switch kind {
        case .scroll:
            if rebaseScroll {
                scrollCenter = now.center
                return 0
            }
            let dx = now.center.x - scrollCenter.x
            let dy = now.center.y - scrollCenter.y
            let distance = hypot(dx, dy)
            let frameTravel = hypot(now.center.x - previous.center.x, now.center.y - previous.center.y)
            // Retain tiny movements so slow deliberate strokes still accumulate.
            // Reduce the dead zone during faster motion to keep it responsive.
            let deadZone = max(0.0003, 0.0014 - frameTravel * 0.15)
            if distance > deadZone {
                let scale = (distance - deadZone) / distance
                scrollDelta = CGPoint(x: dx * scale, y: dy * scale)
                scrollCenter.x += scrollDelta.x
                scrollCenter.y += scrollDelta.y
            }
            return 0
        case .magnify:
            guard min(previous.distance, now.distance) >= 0.06 else { return 0 }
            return max(-0.14, min(0.14, log(now.distance / previous.distance)))
        case .rotate:
            guard min(previous.distance, now.distance) >= 0.10 else { return 0 }
            return max(-8, min(8, Self.angleDelta(now.angle, previous.angle) * 180 / .pi))
        case nil:
            return 0
        }
    }

    private static func angleDelta(_ current: Double, _ previous: Double) -> Double {
        let delta = current - previous
        return atan2(sin(delta), cos(delta))
    }
}

enum MapGestureEvent {
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

    /// AppKit decodes these Quartz gesture fields into magnify(with:) and rotate(with:).
    static func make(_ kind: MapGesture.Kind, _ phase: Phase, amount: Double, at location: CGPoint) -> CGEvent? {
        guard kind != .scroll, let event = CGEvent(source: nil),
              let gestureType = CGEventType(rawValue: 29),
              let subtype = CGEventField(rawValue: 110),
              let value = CGEventField(rawValue: kind == .magnify ? 113 : 114),
              let phaseField = CGEventField(rawValue: 132) else { return nil }
        event.type = gestureType
        event.location = location
        event.setIntegerValueField(subtype, value: kind.rawValue)
        event.setDoubleValueField(value, value: amount)
        event.setIntegerValueField(phaseField, value: phase.rawValue)
        return event
    }
}
