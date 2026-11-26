// The middle-click event transformation is adapted from MiddleClick (GPL-3.0).
// See THIRD_PARTY_NOTICES.md. Magic Mouse Toolkit is licensed under GPL-3.0-only.

import CoreGraphics
import QuartzCore
import AppKit

/// CGEventTap の C コールバック（capture 不可のためグローバル関数）。
private func eventInterceptorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    EventInterceptor.shared.handle(type: type, event: event)
}

/// 1本の CGEventTap で3役を兼ねる:
/// - スクロール監視（第2層・第3層ベトの情報源。ScrollMonitor役）
/// - 物理クリック監視（第4層ベトの情報源）
/// - 2本指物理クリック→ミドルクリック変換
///
/// コールバック規律: アロケーション・ログ・UserDefaults 読み取り禁止。
/// SettingsSnapshot と共有状態の読み取り + 整数フィールド書き換えのみ。
///
/// 権限喪失の検知と復旧は本クラスの責務ではなく PermissionMonitor + AppDelegate が担う
/// (SAFETY.md参照)。理由: `.tapDisabledByUserInput` はアクセシビリティ権限を
/// システム設定でOFFにした際、実機では配送されないことが確認されている(剥奪と同時に
/// タップへのイベント配送自体が止まるため)。このコールバック内で権限喪失を検知する
/// 設計は機能しないので採用しない。
final class EventInterceptor {
    static let shared = EventInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// メニューバーの状態表示用
    var isRunning: Bool { eventTap != nil }

    private init() {
        // .settingsChanged の購読は生存期間中1回だけ行う。start()/stop() のたびに
        // 登録し直すと、権限失効→復旧のサイクルを重ねるごとにオブザーバが重複登録され、
        // updateEnabledState() が多重に呼ばれるようになるため。
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .settingsChanged, object: nil)
    }

    func start() {
        guard eventTap == nil else { return }

        let eventsOfInterest: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << 29) // Quartz gesture envelope
            | (1 << 32) // Smart magnify

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: eventInterceptorCallback,
            userInfo: nil
        ) else {
            MMTLog.log("イベントタップ作成失敗(アクセシビリティ権限を確認)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        MMTLog.log("イベントタップ作成成功(クリック監視・ミドルクリック変換が有効)")

        updateEnabledState()
    }

    /// タップを完全に破棄する。`tapEnable(false)` だけでなく `CFMachPortInvalidate` まで
    /// 行うのが重要: WindowServer側にポート登録が残ったままだと、権限剥奪直後の
    /// フリーズからの回復が遅れる/回復しない可能性があるため(SAFETY.md参照)。
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        // タップ破棄後に再開しても押下中・変換途中の状態が残らないようにする
        // （残っていると再有効化後の最初のクリックが誤ってミドルUpに変換される）
        clearSharedInputState()
    }

    /// 押下中・変換途中・スクロール受け渡し中の共有状態を初期化する。
    /// タップ無効化(updateEnabledState)・タップ破棄(stop)の両方から呼ぶ
    private func clearSharedInputState() {
        let shared = SharedState.shared
        shared.convertingToMiddle = false
        shared.leftButtonDown = false
        shared.rightButtonDown = false
        shared.momentumActive = false
        shared.trackpadScrollPassthrough = false
        shared.trackpadMomentumEligibleUntil = -1e9
    }

    @objc private func settingsChanged() {
        updateEnabledState()
    }

    /// master enable OFF 時は tap 自体を無効化する（タップ判定もベト先も不要なため）。
    /// middleClick のみ OFF でタップ有効の場合は tap は生かす（第2層のスクロール監視のため）。
    ///
    /// 注意: ここでは SettingsStore のスナップショットではなく AppSettings を直接読む。
    /// スナップショットの更新も同じ .settingsChanged 通知で行われるため、オブザーバの
    /// 実行順序によっては1世代古い値を読んでしまい、有効トグルが1テンポずれる
    /// （OFF→ONに戻しても無効のままになる）バグの原因になる。
    private func updateEnabledState() {
        guard let tap = eventTap else { return }
        let enabled = AppSettings.shared.enabled
        if !enabled {
            TrackpadModeController.shared.deactivate()
            // OFF 中は mouseUp を取りこぼすため、変換途中・押下中の状態を必ずクリアする
            clearSharedInputState()
        }
        CGEvent.tapEnable(tap: tap, enable: enabled)
        if enabled {
            TrackpadModeController.shared.restorePreferredMode()
        }
        MMTLog.log("イベントタップ: \(enabled ? "有効化" : "無効化")")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // コールバックが重くてシステムに自動無効化された場合のみ、その場で再有効化してよい。
        if type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // システム設定でユーザーがアクセシビリティ/入力監視をOFFにした場合。
        // 実機検証では、権限剥奪と同時にこのタップへのイベント配送自体が止まり、
        // このイベントがコールバックに配送されないことが確認されている
        // (~/Library/Logs/MagicMouseToolkit.log に復旧ログが一切残らなかった)。
        // つまりここで何をしても頼りにできない。絶対に tapEnable(true) は呼ばない
        // (呼んでも意味が無い上、万一配送された場合に同期ループの引き金になりうる)。
        // 権限喪失の検知と復旧は PermissionMonitor が別経路(ポーリング)で行う。
        if type == .tapDisabledByUserInput {
            return Unmanaged.passUnretained(event)
        }

        let shared = SharedState.shared
        let now = CACurrentMediaTime()

        if shared.trackpadModeActive, now - shared.lastFrameAt < 0.5,
           now - shared.builtInTrackpadLastFrameAt >= 0.5 {
            // The Magic Mouse's native one-finger double tap conflicts with drag arming.
            let isSmartMagnify = type.rawValue == 32
                || (type.rawValue == 29 && CGEventField(rawValue: 110).map {
                    event.getIntegerValueField($0) == 22
                } == true)
            if isSmartMagnify { return nil }
        }

        switch type {
        case .mouseMoved, .leftMouseDragged:
            if type == .leftMouseDragged, shared.convertingToMiddle {
                event.type = .otherMouseDragged
                event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                return Unmanaged.passUnretained(event)
            }
            guard shared.trackpadModeActive, !shared.buttonDown,
                  event.getIntegerValueField(.eventSourceUserData) != SynthesizedClick.signature,
                  !(shared.builtInTrackpadFingerCount > 0 && now - shared.builtInTrackpadLastFrameAt < 0.08) else {
                return Unmanaged.passUnretained(event)
            }
            let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX),
                                y: event.getDoubleValueField(.mouseEventDeltaY))
            if TrackpadModeController.shared.consumeOpticalMotion(delta, at: now) { return nil }
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            if event.getIntegerValueField(.eventSourceUserData) == TouchScrollOutput.signature {
                return Unmanaged.passUnretained(event)
            }
            if shared.trackpadModeActive {
                // Magic Mouse scrolling comes from contact frames. Only the built-in
                // trackpad's native sequence and its momentum pass through this path.
                let builtIn = shared.builtInTrackpadFingerCount >= 2
                    && now - shared.builtInTrackpadLastFrameAt < 0.08
                let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                let active = shared.trackpadScrollPassthrough
                if momentum == 3, active {
                    shared.trackpadScrollPassthrough = false
                    shared.trackpadMomentumEligibleUntil = -1e9
                } else if scrollPhase == 4 || scrollPhase == 8 {
                    guard active || builtIn else { return nil }
                    shared.trackpadScrollPassthrough = false
                    shared.trackpadMomentumEligibleUntil = now + 0.12
                } else if builtIn || (momentum == 1 || momentum == 2)
                            && (active || now <= shared.trackpadMomentumEligibleUntil) {
                    shared.trackpadScrollPassthrough = true
                    shared.trackpadMomentumEligibleUntil = -1e9
                } else if !active || shared.fingerCount > 0 {
                    return nil
                }
            }

            // Magic Mouse はタップ程度の接触でもデルタ0のスクロールイベント(phase通知)を
            // 発生させるため、実際に移動量のあるイベントだけを「スクロール」として記録する。
            // そうしないと全タップがスクロールベトで潰される。
            let d1 = abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let d2 = abs(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            if d1 + d2 > 0 {
                shared.lastScrollAt = now
            }
            let phase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            shared.momentumActive = (phase == 1 || phase == 2)  // began / continued

            // 横スクロール無効化: Axis2(横)の3種のデルタ表現(整数生値・整数ポイント値・
            // 固定小数点値)をすべてゼロ化する。慣性フェーズのイベントも同じフィールドを
            // 持つため、この処理だけで横方向の慣性スクロールも止まる。
            if SettingsStore.shared.verticalScrollOnly {
                event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            if event.getIntegerValueField(.eventSourceUserData) == SynthesizedClick.signature {
                MMTLog.log("[診断] 合成leftMouseDownがHIDタップを通過(注入成功)")
                return Unmanaged.passUnretained(event)
            }
            shared.leftButtonDown = true
            if SettingsStore.shared.middleClickEnabled
                && shared.fingerCount == 2
                && (now - shared.lastFrameAt) < 0.08 {
                shared.convertingToMiddle = true
                event.type = .otherMouseDown
                event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if event.getIntegerValueField(.eventSourceUserData) == SynthesizedClick.signature {
                return Unmanaged.passUnretained(event)
            }
            shared.leftButtonDown = false
            shared.lastButtonUpAt = now
            if shared.convertingToMiddle {
                shared.convertingToMiddle = false
                event.type = .otherMouseUp
                event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            }
            return Unmanaged.passUnretained(event)

        case .rightMouseDown:
            if event.getIntegerValueField(.eventSourceUserData) == SynthesizedClick.signature {
                return Unmanaged.passUnretained(event)
            }
            shared.rightButtonDown = true
            return Unmanaged.passUnretained(event)

        case .rightMouseUp:
            if event.getIntegerValueField(.eventSourceUserData) == SynthesizedClick.signature {
                return Unmanaged.passUnretained(event)
            }
            shared.rightButtonDown = false
            shared.lastButtonUpAt = now
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
