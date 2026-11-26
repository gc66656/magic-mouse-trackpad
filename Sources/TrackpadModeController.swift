import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation
import QuartzCore

/// 仮想トラックパッドモード。有効化中はマルチタッチのストロークをカーソル移動に変換し、
/// タップをクリックとして合成する。プロトタイプ(prototypes/virtual_trackpad/main.swift)の
/// 検証済みロジックを、本体の SharedState/SettingsSnapshot/SynthesizedClick に接続して移植したもの。
///
/// 規律(手順書 magic-mouse-toolkit-仮想トラックパッド実装手順.md 準拠):
/// MTコールバック(handleContactFrame)内では CGEvent 生成・メモリ確保・ログ出力を行わず、
/// os_unfair_lock で保護したアキュムレータへの書き込みのみに留める。実際の CGEvent 生成/post は
/// メインキュー上の 120Hz タイマー(drainAndPost)で行う。
final class TrackpadModeController: ObservableObject {
    static let shared = TrackpadModeController()

    private init() {
        refreshDisplayBounds()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDisplayBounds()
        }
    }

    private var drainTimer: DispatchSourceTimer?
    /// Main queue only.
    private lazy var moveEventSource = CGEventSource(stateID: .hidSystemState)

    // 全ディスプレイのbounds(CG座標・左上原点)。120Hzのdrainループから毎回
    // CGGetActiveDisplayListを呼ぶのは避け、着脱/配置変更通知でのみ更新する。
    private var displayLock = os_unfair_lock()
    private var displayBounds: [CGRect] = []

    private func refreshDisplayBounds() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.map { CGDisplayBounds($0) }
        os_unfair_lock_lock(&displayLock)
        displayBounds = bounds
        os_unfair_lock_unlock(&displayLock)
    }

    private func currentDisplayBounds() -> [CGRect] {
        os_unfair_lock_lock(&displayLock)
        let bounds = displayBounds
        os_unfair_lock_unlock(&displayLock)
        return bounds
    }

    /// 移動先がどのディスプレイにも属さない場合、軸ごとに分解して通る方だけ動かす
    /// (壁沿いの滑走。物理マウスと同じ挙動)。ディスプレイ間の隙間へワープするのを防ぐ。
    private func resolvedPosition(current: CGPoint, target: CGPoint) -> CGPoint {
        let bounds = currentDisplayBounds()
        guard !bounds.isEmpty else { return current }
        func contains(_ point: CGPoint) -> Bool {
            bounds.contains { $0.contains(point) }
        }
        if contains(target) { return target }
        let xOnly = CGPoint(x: target.x, y: current.y)
        if contains(xOnly) { return xOnly }
        let yOnly = CGPoint(x: current.x, y: target.y)
        if contains(yOnly) { return yOnly }
        return current
    }

    private var accLock = os_unfair_lock()
    private var accDX: Double = 0
    private var accDY: Double = 0
    private var pendingClicks = 0
    private var pendingDoubleClicks = 0
    private var pendingRightClick = false
    private var pendingDragDelta = CGPoint.zero
    private var pendingDragRelease = false
    private var acceptingTouches = false

    // Main queue only. The event tap and touch output share the button state.
    private var dragLocation: CGPoint?
    private var nativeCursorDetached = false
    private var pointerRemainder = CGPoint.zero
    private var lastTap: (time: Double, position: CGPoint)?
    private var mapGesture = MapGesture()
    private var pendingScroll = CGPoint.zero
    private var scrollContactDeadline: Double?
    private let scrollContactGrace: Double = 0.035
    private var touchScroll = TouchScrollOutput()
    private var naturalScrolling = true
    private var pendingMapKind: MapGesture.Kind?
    private var pendingMapAmount = 0.0
    private var pendingMapEnd = false
    // Main queue only.
    private var activeMapKind: MapGesture.Kind?
    private var dragCandidate = false
    private var dragging = false
    private var dragMotionSource = DragMotionSource()
    private var resumingAfterMultipleTouches = false
    private let restingRadius = 0.008
    private let tapMotionLimit = 0.06
    private let dragStartDistance = 0.030
    private let secondTouchHoldDelay: TimeInterval = 0.125
    private let retouchRadius = 0.14
    private var doubleTapInterval: TimeInterval = 0.30
    private let modePreferenceKey = "mmt.trackpad.preferredActive"
    private var accTogglePending = false

    // 現在追跡中の指(1本のみ)。2本以上では追跡を中断し、スクロールに専念する。
    private var trackedID: Int32?
    private var lastTouchPos = MTPoint(x: 0, y: 0)

    // タップ判定用の追跡状態(タッチ開始時にリセット)
    private var touchStartPos = CGPoint.zero
    private var filteredTouchPos = CGPoint.zero
    private var lastMotionTime: Double = 0
    private var motionSpeed = 0.0
    private var touchStartTime: Double = 0
    private var tapDisqualified = false
    private var touchPathLength: Double = 0
    private var touchMaxVelocity: Double = 0
    private var touchFrameCount: Int = 0

    private struct TwoFingerTap {
        let first: MTTouch
        let second: MTTouch
        let startedAt: Double
        var frames = 0
        var firstReleaseAt: Double?
    }

    private var twoFingerTap: TwoFingerTap?

    // モード解除用の3本指タップ追跡。MTコールバック内では数値状態だけを更新し、
    // 実際の切り替えは drainAndPost からメインキューへ渡す。
    private var threeFingerTracking = false
    private var threeFingerStartTime: Double = 0
    private var threeFingerStartPos = MTPoint(x: 0, y: 0)
    private var threeFingerLastPos = MTPoint(x: 0, y: 0)
    private var threeFingerPathLength: Double = 0
    private var threeFingerMaxVelocity: Double = 0
    private var threeFingerFrameCount: Int = 0
    private var lastThreeFingerToggleTapAt: Double = -1e9
    private let trackpadToggleDoubleTapWindow: Double = 0.45

    @Published private(set) var isActive = false

    func toggle() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.toggle() }
            return
        }
        UserDefaults.standard.set(!isActive, forKey: modePreferenceKey)
        restorePreferredMode()
    }

    func restorePreferredMode() {
        let preferred = UserDefaults.standard.object(forKey: modePreferenceKey) as? Bool ?? true
        if preferred {
            activate()
        } else {
            deactivate()
        }
    }

    private func activate() {
        guard !isActive, AppSettings.shared.enabled, EventInterceptor.shared.isRunning else { return }
        isActive = true
        naturalScrolling = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        os_unfair_lock_lock(&accLock)
        resetTrackingState()
        acceptingTouches = true
        doubleTapInterval = min(NSEvent.doubleClickInterval, 0.30)
        accDX = 0
        accDY = 0
        pendingClicks = 0
        pendingDoubleClicks = 0
        pendingRightClick = false
        accTogglePending = false
        os_unfair_lock_unlock(&accLock)

        SharedState.shared.trackpadScrollPassthrough = false
        SharedState.shared.trackpadMomentumEligibleUntil = -1e9
        SharedState.shared.fingerCount = 0
        SharedState.shared.trackpadModeActive = true

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        timer.setEventHandler { [weak self] in self?.drainAndPost() }
        timer.resume()
        drainTimer = timer

        MMTLog.log("[診断] TrackpadMode: 有効化")
        TrackpadModeHUD.flash(active: true)
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false

        drainTimer?.cancel()
        drainTimer = nil
        os_unfair_lock_lock(&accLock)
        acceptingTouches = false
        os_unfair_lock_unlock(&accLock)
        cancelTouchSequence()
        SharedState.shared.trackpadScrollPassthrough = false
        SharedState.shared.trackpadMomentumEligibleUntil = -1e9
        SharedState.shared.fingerCount = 0
        SharedState.shared.trackpadModeActive = false

        MMTLog.log("[診断] TrackpadMode: 無効化")
        TrackpadModeHUD.flash(active: false)
    }

    func cancelTouchSequence() {
        os_unfair_lock_lock(&accLock)
        resetTrackingState()
        accDX = 0
        accDY = 0
        pendingClicks = 0
        pendingDoubleClicks = 0
        pendingRightClick = false
        pendingDragDelta = .zero
        pendingDragRelease = false
        accTogglePending = false
        os_unfair_lock_unlock(&accLock)

        touchScroll.cancel()
        postMapGesture(kind: nil, amount: 0, ended: true)
        releaseDrag()
        setNativeCursorDetached(false)
        pointerRemainder = .zero
    }

    private func resetTrackingState() {
        twoFingerTap = nil
        mapGesture = MapGesture()
        pendingMapKind = nil
        pendingMapAmount = 0
        pendingMapEnd = false
        pendingScroll = .zero
        scrollContactDeadline = nil
        lastTap = nil
        dragCandidate = false
        dragging = false
        dragMotionSource = DragMotionSource()
        resumingAfterMultipleTouches = false
        trackedID = nil
        lastTouchPos = MTPoint(x: 0, y: 0)
        touchStartPos = .zero
        touchStartTime = 0
        touchPathLength = 0
        touchMaxVelocity = 0
        touchFrameCount = 0
        lastThreeFingerToggleTapAt = -1e9
        resetThreeFingerTracking()
    }

    private func resetThreeFingerTracking() {
        threeFingerTracking = false
        threeFingerStartTime = 0
        threeFingerStartPos = MTPoint(x: 0, y: 0)
        threeFingerLastPos = MTPoint(x: 0, y: 0)
        threeFingerPathLength = 0
        threeFingerMaxVelocity = 0
        threeFingerFrameCount = 0
    }

    /// MTコールバック経由(TouchGestureManager)から呼ばれる。CGEvent生成・ログ出力禁止。
    func handleContactFrame(touches: UnsafeBufferPointer<MTTouch>, timestamp: Double, settings: SettingsSnapshot) {
        os_unfair_lock_lock(&accLock)
        defer { os_unfair_lock_unlock(&accLock) }
        guard acceptingTouches else { return }

        // モード中は TouchGestureManager が早期returnするため、指本数と時刻をここで共有する。
        var touchingCount = 0
        var firstIndex: Int?
        var secondIndex: Int?
        var trackedIndex: Int?
        for index in touches.indices where touches[index].state == 4 {
            touchingCount += 1
            if touchingCount == 1 { firstIndex = index }
            if touchingCount == 2 { secondIndex = index }
            if touches[index].identifier == trackedID { trackedIndex = index }
        }
        SharedState.shared.fingerCount = touchingCount
        SharedState.shared.lastFrameAt = timestamp

        if dragging {
            switch dragMotionSource.acceptTouch(at: timestamp) {
            case .ignore:
                // Optical ownership needs only the original finger's contact state.
                if trackedIndex == nil {
                    evaluateTapAndReset(endTime: timestamp, settings: settings)
                    resumingAfterMultipleTouches = touchingCount > 0
                }
                return
            case .rebase:
                if touchingCount == 1, let trackedIndex {
                    let contact = touches[trackedIndex].normalized.position
                    lastTouchPos = contact
                    filteredTouchPos = CGPoint(x: Double(contact.x), y: Double(contact.y))
                    lastMotionTime = timestamp
                    motionSpeed = 0
                    pendingDragDelta = .zero
                    return
                }
            case .move:
                break
            }
        }

        let firstTouch = firstIndex.map { touches[$0] }
        let secondTouch = secondIndex.map { touches[$0] }
        if let deadline = scrollContactDeadline, timestamp >= deadline {
            endTwoFingerMotion()
        }
        if touchingCount == 2, let firstTouch, let secondTouch, !threeFingerTracking {
            if !mapGesture.tracks(firstTouch, secondTouch) {
                endTwoFingerMotion()
            }
            let rebaseScroll = scrollContactDeadline != nil
            scrollContactDeadline = nil
            let delta = mapGesture.update(firstTouch, secondTouch, rebaseScroll: rebaseScroll)
            pendingScroll.x += mapGesture.scrollDelta.x
            pendingScroll.y += mapGesture.scrollDelta.y
            if let kind = mapGesture.kind {
                twoFingerTap = nil
                if kind != .scroll {
                    pendingMapKind = kind
                    pendingMapAmount += delta
                }
            }
        } else if touchingCount == 1, let firstTouch, mapGesture.kind == .scroll,
                  mapGesture.tracks(firstTouch) {
            if scrollContactDeadline == nil {
                scrollContactDeadline = timestamp + scrollContactGrace
            }
            return
        } else {
            endTwoFingerMotion()
        }

        if touchingCount >= 3 { twoFingerTap = nil }

        if touchingCount >= 3,
           settings.threeFingerTapEnabled,
           settings.threeFingerTapAction.isTrackpadToggle {
            var positionSumX: Float = 0
            var positionSumY: Float = 0
            var maxVelocity = 0.0
            for touch in touches where touch.state == 4 {
                positionSumX += touch.normalized.position.x
                positionSumY += touch.normalized.position.y
                let velocity = touch.normalized.velocity
                maxVelocity = max(maxVelocity, hypot(Double(velocity.x), Double(velocity.y)))
            }
            let centroid = MTPoint(
                x: positionSumX / Float(touchingCount),
                y: positionSumY / Float(touchingCount))
            if threeFingerTracking {
                let dx = Double(centroid.x - threeFingerLastPos.x)
                let dy = Double(centroid.y - threeFingerLastPos.y)
                threeFingerPathLength += (dx * dx + dy * dy).squareRoot()
                threeFingerLastPos = centroid
                threeFingerMaxVelocity = max(threeFingerMaxVelocity, maxVelocity)
                threeFingerFrameCount += 1
            } else {
                threeFingerTracking = true
                threeFingerStartTime = timestamp
                threeFingerStartPos = centroid
                threeFingerLastPos = centroid
                threeFingerPathLength = 0
                threeFingerMaxVelocity = maxVelocity
                threeFingerFrameCount = 1
            }

            interruptSingleFingerGesture()
            return
        }

        // 3本指を順に離す途中は2本指スクロールへ遷移させず、全指リリース時に確定する。
        if threeFingerTracking {
            if touchingCount == 0 {
                let dx = Double(threeFingerLastPos.x - threeFingerStartPos.x)
                let dy = Double(threeFingerLastPos.y - threeFingerStartPos.y)
                let straightDistance = (dx * dx + dy * dy).squareRoot()
                let duration = timestamp - threeFingerStartTime
                let isTap = duration <= settings.tapMaxDuration
                    && straightDistance <= settings.tapMaxStraightDistance
                    && threeFingerPathLength <= settings.tapMaxPathLength
                    && threeFingerMaxVelocity <= settings.tapMaxVelocity
                    && threeFingerFrameCount >= settings.tapMinFrames
                resetThreeFingerTracking()
                resumingAfterMultipleTouches = false
                if isTap {
                    if timestamp - lastThreeFingerToggleTapAt <= trackpadToggleDoubleTapWindow {
                        lastThreeFingerToggleTapAt = -1e9
                        accTogglePending = true
                    } else {
                        lastThreeFingerToggleTapAt = timestamp
                    }
                } else {
                    lastThreeFingerToggleTapAt = -1e9
                }
            }
            return
        }

        let waitingForSecondRelease = touchingCount <= 2 && mapGesture.kind == nil && updateTwoFingerTap(
            first: firstTouch, second: secondTouch,
            at: timestamp, settings: settings
        )

        // 2本以上ではカーソル・タップ追跡を中断し、未ドレインの移動量も破棄する。
        if touchingCount >= 2 {
            interruptSingleFingerGesture()
            return
        }

        if waitingForSecondRelease { return }

        guard let touch = firstTouch else {
            resumingAfterMultipleTouches = false
            evaluateTapAndReset(endTime: timestamp, settings: settings)
            return
        }

        // A remaining finger belongs to the multi-finger gesture until every finger lifts.
        guard !resumingAfterMultipleTouches else { return }

        let position = CGPoint(x: Double(touch.normalized.position.x), y: Double(touch.normalized.position.y))
        if trackedID != touch.identifier {
            if trackedID != nil {
                interruptSingleFingerGesture()
                return
            }
            dragCandidate = !resumingAfterMultipleTouches && (lastTap.map {
                timestamp - $0.time <= doubleTapInterval
                    && hypot(position.x - $0.position.x, position.y - $0.position.y) <= retouchRadius
            } ?? false)
            lastTap = nil
            dragMotionSource = DragMotionSource()
            // 新規タッチ開始。デルタ0で基準位置だけ記録(いきなり跳ばないように)
            trackedID = touch.identifier
            lastTouchPos = touch.normalized.position
            touchStartPos = position
            filteredTouchPos = position
            lastMotionTime = timestamp
            motionSpeed = 0
            touchStartTime = timestamp
            tapDisqualified = resumingAfterMultipleTouches
            touchPathLength = 0
            touchMaxVelocity = 0
            touchFrameCount = 0
            return
        }

        let ndx = Double(touch.normalized.position.x - lastTouchPos.x)
        let ndy = Double(touch.normalized.position.y - lastTouchPos.y)
        lastTouchPos = touch.normalized.position

        touchPathLength += (ndx * ndx + ndy * ndy).squareRoot()
        let velocity = touch.normalized.velocity
        let velocityMagnitude = (Double(velocity.x) * Double(velocity.x) + Double(velocity.y) * Double(velocity.y)).squareRoot()
        touchMaxVelocity = max(touchMaxVelocity, velocityMagnitude)
        touchFrameCount += 1

        let dx = position.x - touchStartPos.x
        let dy = position.y - touchStartPos.y
        let displacement = hypot(dx, dy)
        if displacement > tapMotionLimit {
            tapDisqualified = true
        }

        if dragCandidate && !dragging {
            guard displacement >= dragStartDistance else { return }
            dragging = true
            // Keep the pointer at the click location until the finger clears the dead zone.
            let fraction = max(0, dragStartDistance - restingRadius) / displacement
            filteredTouchPos = CGPoint(
                x: touchStartPos.x + dx * fraction,
                y: touchStartPos.y + dy * fraction
            )
            lastMotionTime = timestamp
        }

        // Give the second finger a short landing window before moving the pointer.
        guard dragging || timestamp - touchStartTime >= 0.025 else { return }
        let delta = pointerDelta(to: position, at: timestamp, gain: settings.trackpadModeGain)
        if dragging {
            if delta != .zero { dragMotionSource.recordTouchMotion(at: timestamp) }
            pendingDragDelta.x += delta.x
            pendingDragDelta.y += delta.y
        } else {
            accDX += delta.x
            accDY += delta.y
        }
    }

    private func endTwoFingerMotion() {
        if let kind = mapGesture.kind, kind != .scroll {
            pendingMapEnd = true
        }
        mapGesture = MapGesture()
        scrollContactDeadline = nil
    }

    /// During the held gesture, consume native movement and route relative optical
    /// deltas through the same drag output as touch. Native cursor coordinates are
    /// never forwarded while a synthetic drag is active.
    func consumeOpticalMotion(_ delta: CGPoint, at time: Double) -> Bool {
        os_unfair_lock_lock(&accLock)
        defer { os_unfair_lock_unlock(&accLock) }
        guard acceptingTouches else { return false }
        if pendingDragRelease { return true }
        guard trackedID != nil, dragCandidate else { return false }

        switch dragMotionSource.acceptOptical(delta, at: time, duringDrag: dragging) {
        case .ignore:
            break
        case .begin(let initialTravel):
            dragging = true
            pendingDragDelta = initialTravel
            filteredTouchPos = CGPoint(x: Double(lastTouchPos.x), y: Double(lastTouchPos.y))
            lastMotionTime = time
            motionSpeed = 0
        case .continueMoving:
            pendingDragDelta.x += delta.x
            pendingDragDelta.y += delta.y
        }
        return true
    }

    /// A short, nearly stationary touch must include both fingers and end with both lifted.
    private func updateTwoFingerTap(
        first: MTTouch?, second: MTTouch?, at time: Double, settings: SettingsSnapshot
    ) -> Bool {
        let shared = SharedState.shared
        guard settings.twoFingerTapEnabled, !shared.buttonDown else {
            twoFingerTap = nil
            return false
        }
        if twoFingerTap == nil, let first, let second, !resumingAfterMultipleTouches, !dragging {
            let startTime = trackedID == nil ? time : touchStartTime
            if time - startTime <= settings.twoFingerSyncWindow,
               trackedID == nil || touchPathLength <= 0.025 {
                twoFingerTap = TwoFingerTap(first: first, second: second, startedAt: startTime)
            }
        }
        guard var tap = twoFingerTap else { return false }
        let releaseWindow = min(settings.twoFingerSyncWindow, 0.09)
        guard time - tap.startedAt <= settings.tapMaxDuration,
              shared.lastButtonUpAt < tap.startedAt,
              time - (tap.firstReleaseAt ?? time) <= releaseWindow else {
            twoFingerTap = nil
            return false
        }
        guard let first else {
            if tap.frames >= settings.tapMinFrames { pendingRightClick = true }
            twoFingerTap = nil
            return false
        }

        let motionLimit = min(settings.tapMaxStraightDistance, 0.035)
        func stayedNearStart(_ touch: MTTouch) -> Bool {
            let start = touch.identifier == tap.first.identifier ? tap.first : tap.second
            guard start.identifier == touch.identifier else { return false }
            let dx = Double(touch.normalized.position.x - start.normalized.position.x)
            let dy = Double(touch.normalized.position.y - start.normalized.position.y)
            return hypot(dx, dy) <= motionLimit
        }
        guard stayedNearStart(first),
              second.map({ tap.firstReleaseAt == nil && stayedNearStart($0) }) ?? true else {
            twoFingerTap = nil
            return false
        }
        if second != nil {
            tap.frames += 1
        } else if tap.firstReleaseAt == nil {
            tap.firstReleaseAt = time
        }
        twoFingerTap = tap
        return second == nil
    }

    private func pointerDelta(to position: CGPoint, at timestamp: Double, gain: Double) -> CGPoint {
        let elapsed = max(0.004, timestamp - lastMotionTime)
        lastMotionTime = timestamp
        let dx = position.x - filteredTouchPos.x
        let dy = position.y - filteredTouchPos.y
        let distance = hypot(dx, dy)
        let travel = max(0, distance - restingRadius)
        // A time-based speed estimate keeps the response consistent across frame rates.
        motionSpeed += (travel / elapsed - motionSpeed) * (1 - exp(-elapsed / 0.026))
        guard travel > 0 else { return .zero }

        let fraction = travel / distance
        let filteredDX = dx * fraction
        let filteredDY = dy * fraction
        filteredTouchPos.x += filteredDX
        filteredTouchPos.y += filteredDY

        let speedFraction = min(1, max(0, (motionSpeed - 0.18) / 2.6))
        let ramp = speedFraction * speedFraction * (3 - 2 * speedFraction)
        let multiplier = dragging ? 0.58 + 0.80 * ramp : 0.45 + 1.85 * ramp
        return CGPoint(x: filteredDX * gain * multiplier, y: -filteredDY * gain * multiplier)
    }

    private func interruptSingleFingerGesture() {
        trackedID = nil
        lastTap = nil
        dragCandidate = false
        resumingAfterMultipleTouches = true
        accDX = 0
        accDY = 0
        if dragging {
            dragging = false
            pendingDragRelease = true
        }
    }

    /// タッチ終了(リリース)時にタップかどうかを判定し、成立していればクリックフラグを立てる。
    /// CGEventの生成はここでは行わない(MTコールバックの規律)。
    private func evaluateTapAndReset(endTime: Double, settings: SettingsSnapshot) {
        guard trackedID != nil else { return }
        trackedID = nil
        defer { dragCandidate = false }
        if dragging {
            dragging = false
            pendingDragRelease = true
            return
        }

        let dx = Double(lastTouchPos.x) - touchStartPos.x
        let dy = Double(lastTouchPos.y) - touchStartPos.y
        let duration = endTime - touchStartTime

        let minimumFrames = dragCandidate ? max(1, settings.tapMinFrames - 1) : settings.tapMinFrames
        let isTap = !tapDisqualified && duration <= settings.tapMaxDuration
            && hypot(dx, dy) <= min(settings.tapMaxStraightDistance, tapMotionLimit)
            && touchPathLength <= min(settings.tapMaxPathLength, 0.10)
            && touchMaxVelocity <= settings.tapMaxVelocity
            && touchFrameCount >= minimumFrames

        guard isTap else { return }
        if dragCandidate {
            pendingDoubleClicks += 1
        } else {
            pendingClicks += 1
            if touchPathLength <= 0.035 {
                lastTap = (endTime, touchStartPos)
            }
        }
    }

    /// Quartz can move the cursor before an event tap discards the movement event.
    /// Detach it from hardware while touch owns the drag and restore it on release or handoff.
    private func setNativeCursorDetached(_ detached: Bool) {
        guard detached != nativeCursorDetached else { return }
        let result = CGAssociateMouseAndMouseCursorPosition(detached ? 0 : 1)
        if result == .success {
            nativeCursorDetached = detached
        }
    }

    private func postMouseEvent(_ type: CGEventType, at location: CGPoint) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: moveEventSource,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return false }
        event.setIntegerValueField(.eventSourceUserData, value: SynthesizedClick.signature)
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        if type == .leftMouseDragged, let dragLocation {
            event.setDoubleValueField(.mouseEventDeltaX, value: location.x - dragLocation.x)
            event.setDoubleValueField(.mouseEventDeltaY, value: location.y - dragLocation.y)
        }
        if nativeCursorDetached, type == .leftMouseDragged, location != dragLocation {
            // A detached cursor needs a position update in addition to the app's drag event.
            _ = CGWarpMouseCursorPosition(location)
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func releaseDrag() {
        guard let dragLocation else { return }
        _ = postMouseEvent(.leftMouseUp, at: dragLocation)
        self.dragLocation = nil
    }

    private func postMapGesture(kind: MapGesture.Kind?, amount: Double, ended: Bool) {
        guard kind != nil || activeMapKind != nil,
              let point = CGEvent(source: nil)?.location else { return }
        if let kind {
            if activeMapKind == nil {
                MapGestureEvent.make(kind, .began, amount: 0, at: point)?.post(tap: .cghidEventTap)
                activeMapKind = kind
                MMTLog.log(kind == .magnify ? "双指捏合缩放开始" : "双指旋转开始")
            }
            if amount != 0 {
                let value = kind == .magnify ? exp(amount) - 1 : amount
                MapGestureEvent.make(kind, .changed, amount: value, at: point)?.post(tap: .cghidEventTap)
            }
        }
        if ended, let activeMapKind {
            MapGestureEvent.make(activeMapKind, .ended, amount: 0, at: point)?.post(tap: .cghidEventTap)
            self.activeMapKind = nil
        }
    }

    /// Called with accLock held. A stationary second touch can hold even when
    /// the sensor has not delivered another contact frame.
    private func beginStationaryHold(at time: Double) -> Bool {
        guard acceptingTouches, trackedID != nil, dragCandidate, !dragging,
              time - touchStartTime >= secondTouchHoldDelay else { return false }
        dragging = true
        filteredTouchPos = CGPoint(x: Double(lastTouchPos.x), y: Double(lastTouchPos.y))
        lastMotionTime = time
        motionSpeed = 0
        return true
    }

    /// The hardware callback only accumulates input. Post events in order on the output queue.
    private func drainAndPost() {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&accLock)
        let delta = CGPoint(x: accDX, y: accDY)
        let clicks = pendingClicks
        let doubleClicks = pendingDoubleClicks
        let rightClick = pendingRightClick
        let mapKind = pendingMapKind
        let mapAmount = pendingMapAmount
        let endMap = pendingMapEnd
        pendingMapKind = nil
        pendingMapAmount = 0
        pendingMapEnd = false
        if let deadline = scrollContactDeadline, now >= deadline {
            endTwoFingerMotion()
        }
        let scroll = pendingScroll
        pendingScroll = .zero
        let scrolling = mapGesture.kind == .scroll
        let touching = SharedState.shared.fingerCount >= 2 || trackedID != nil
        let dragDelta = pendingDragDelta
        let beginHold = beginStationaryHold(at: now)
        let endDrag = pendingDragRelease
        let detachNativeCursor = dragging && dragMotionSource.isTouchDriving(at: now)
        let togglePending = accTogglePending
        accDX = 0
        accDY = 0
        pendingClicks = 0
        pendingDoubleClicks = 0
        pendingRightClick = false
        pendingDragDelta = .zero
        pendingDragRelease = false
        accTogglePending = false
        os_unfair_lock_unlock(&accLock)

        setNativeCursorDetached(detachNativeCursor)

        if delta != .zero, let current = CGEvent(source: nil)?.location {
            // Carry fractional motion across timer ticks so very slow strokes still move.
            let x = delta.x + pointerRemainder.x
            let y = delta.y + pointerRemainder.y
            let step = CGPoint(x: x.rounded(), y: y.rounded())
            pointerRemainder = CGPoint(x: x - step.x, y: y - step.y)
            if step != .zero {
                let target = CGPoint(x: current.x + step.x, y: current.y + step.y)
                _ = postMouseEvent(.mouseMoved, at: resolvedPosition(current: current, target: target))
            }
        }

        for _ in 0..<clicks {
            SynthesizedClick.post(button: .left, clickCount: 1)
        }

        // The first tap was posted with click count 1. Complete the sequence on the second release.
        for _ in 0..<doubleClicks {
            SynthesizedClick.post(button: .left, clickCount: 2)
        }

        if (beginHold || dragDelta != .zero), let current = dragLocation ?? CGEvent(source: nil)?.location {
            if dragLocation == nil, postMouseEvent(.leftMouseDown, at: current) {
                dragLocation = current
            }
            if dragLocation != nil, dragDelta != .zero {
                let target = CGPoint(x: current.x + dragDelta.x, y: current.y + dragDelta.y)
                let position = resolvedPosition(current: current, target: target)
                if postMouseEvent(.leftMouseDragged, at: position) {
                    dragLocation = position
                }
            }
        }

        if endDrag { releaseDrag() }
        if rightClick { SynthesizedClick.post(button: .right) }
        let direction = naturalScrolling ? 1.0 : -1.0
        touchScroll.update(CGPoint(x: scroll.x * 900 * direction, y: -scroll.y * 810 * direction),
                           scrolling: scrolling, touching: touching, now: now)
        postMapGesture(kind: mapKind, amount: mapAmount, ended: endMap)

        if togglePending {
            DispatchQueue.main.async { [weak self] in self?.toggle() }
        }
    }
}
