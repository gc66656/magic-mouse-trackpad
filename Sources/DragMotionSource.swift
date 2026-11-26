import CoreGraphics

/// Selects one pointer source during a held drag. Times come from CACurrentMediaTime.
struct DragMotionSource {
    enum OpticalDecision { case ignore, begin(CGPoint), continueMoving }
    enum TouchDecision { case ignore, rebase, move }

    private let quietPeriod = 0.10
    private var lastTouchMotion: Double?
    private var lastOptical: Double?
    private var opticalSampleStart = -Double.infinity
    private var opticalTravel = CGPoint.zero

    mutating func acceptTouch(at time: Double) -> TouchDecision {
        guard let lastOptical else { return .move }
        guard time - lastOptical >= quietPeriod else { return .ignore }
        self.lastOptical = nil
        return .rebase
    }

    mutating func recordTouchMotion(at time: Double) {
        lastTouchMotion = time
        opticalSampleStart = -.infinity
        opticalTravel = .zero
    }

    func isTouchDriving(at time: Double) -> Bool {
        lastTouchMotion.map { time - $0 < quietPeriod } ?? false
    }

    mutating func acceptOptical(_ delta: CGPoint, at time: Double, duringDrag: Bool) -> OpticalDecision {
        guard delta != .zero else { return .ignore }
        if lastOptical != nil {
            lastOptical = time
            return .continueMoving
        }
        if isTouchDriving(at: time) { return .ignore }
        if duringDrag {
            lastOptical = time
            return .begin(delta)
        }

        // While the second touch is still a tap candidate, reject isolated optical jitter.
        if time - opticalSampleStart > 0.045 {
            opticalSampleStart = time
            opticalTravel = .zero
        }
        opticalTravel.x += delta.x
        opticalTravel.y += delta.y
        guard hypot(opticalTravel.x, opticalTravel.y) >= 3 else { return .ignore }
        lastOptical = time
        return .begin(opticalTravel)
    }
}
