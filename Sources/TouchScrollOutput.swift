import CoreGraphics
import Foundation

/// Main-queue output for a two-finger scroll and its momentum tail.
struct TouchScrollOutput {
    static let signature: Int64 = 0x4D4D_5453
    private var direct = false
    private var momentum = false
    private var velocity = CGPoint.zero
    private var remainder = CGPoint.zero
    private var lastTick: Double?
    private var lastMotion: Double = 0

    mutating func update(_ delta: CGPoint, scrolling: Bool, touching: Bool, now: Double) {
        let elapsed = min(0.025, max(0.004, now - (lastTick ?? now - 1.0 / 120)))
        lastTick = now

        if touching && momentum {
            post(.zero, phase: 0, momentumPhase: 3)
            momentum = false
            velocity = .zero
            remainder = .zero
        }

        if delta != .zero {
            let began = !direct
            direct = true
            let interval = began ? elapsed : min(0.05, max(elapsed, now - lastMotion))
            let instant = CGPoint(x: delta.x / interval, y: delta.y / interval)
            velocity = began ? .zero : CGPoint(x: velocity.x * 0.55 + instant.x * 0.45,
                                               y: velocity.y * 0.55 + instant.y * 0.45)
            lastMotion = now
            post(delta, phase: began ? 1 : 2, momentumPhase: 0)
        }

        if direct && !scrolling {
            post(.zero, phase: 4, momentumPhase: 0)
            direct = false
            remainder = .zero
            if now - lastMotion < 0.065, hypot(velocity.x, velocity.y) >= 45 {
                momentum = true
                post(CGPoint(x: velocity.x * elapsed, y: velocity.y * elapsed), phase: 0, momentumPhase: 1)
            }
            return
        }

        if momentum {
            let decay = exp(-elapsed * 9)
            velocity.x *= decay
            velocity.y *= decay
            if hypot(velocity.x, velocity.y) < 18 {
                post(.zero, phase: 0, momentumPhase: 3)
                momentum = false
                remainder = .zero
            } else {
                post(CGPoint(x: velocity.x * elapsed, y: velocity.y * elapsed), phase: 0, momentumPhase: 2)
            }
        }
    }

    mutating func cancel() {
        if direct { post(.zero, phase: 8, momentumPhase: 0) }
        if momentum { post(.zero, phase: 0, momentumPhase: 3) }
        self = TouchScrollOutput()
    }

    private mutating func post(_ delta: CGPoint, phase: Int64, momentumPhase: Int64) {
        let x = delta.x + remainder.x
        let y = delta.y + remainder.y
        let dx = x.rounded()
        let dy = y.rounded()
        remainder = CGPoint(x: x - dx, y: y - dy)
        if dx == 0, dy == 0, phase == 2 || momentumPhase == 2 { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.signature)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.post(tap: .cghidEventTap)
    }
}
