import AppKit

/// Watches the trackpad for three- and four-finger horizontal swipes.
///
/// **Why an event tap rather than a global monitor.** Measured: with only
/// Accessibility granted, `NSEvent.addGlobalMonitorForEvents` returns a live
/// monitor for `.swipe`, `.gesture` and `.scrollWheel` and then delivers nothing
/// whatsoever — not a single event across dozens of swipes, nor an ordinary
/// two-finger scroll used as a control. That whole class of event is gated
/// behind Input Monitoring, so a tap plus the permission is the only route.
///
/// **Why raw touches rather than `NSEvent.swipe`.** A `.swipe` event only exists
/// when the trackpad's "swipe between pages" setting produces one. Three- and
/// four-finger horizontal swipes are normally bound to Mission Control, where
/// macOS acts on them itself and never synthesises a swipe event. The underlying
/// *touches* are still reported on gesture events either way, so tracking finger
/// positions works under any trackpad configuration.
@MainActor
final class GestureMonitor {

    /// Fires with the horizontal direction of a completed swipe.
    var onSwipe: ((GroupCycleDirection) -> Void)?

    /// Which finger counts to accept. Both by default.
    var fingerCounts: Set<Int> = [3, 4]

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Where each finger started this gesture, keyed by the touch's own identity
    /// — indices are not stable as fingers land and lift.
    private var origins: [ObjectIdentifier: CGPoint] = [:]
    /// One switch per gesture. Without this a long swipe fires continuously as
    /// the fingers keep travelling.
    private var hasFired = false

    /// Fraction of the trackpad's width the fingers must cover, set from the
    /// sensitivity slider. Too small and an ordinary three-finger drag becomes an
    /// accidental group switch.
    var travelThreshold: CGFloat = 0.125

    var isRunning: Bool { tap != nil }

    // MARK: - Lifecycle

    /// Returns false when Input Monitoring has not been granted, so the caller
    /// can surface that rather than silently doing nothing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Permissions.canMonitorInput else { return false }

        // Gesture events carry the raw touches. Type 29 is `NSEventTypeGesture`,
        // which has no `CGEventType` case — it is tapped by raw bit position.
        let mask: CGEventMask = (1 << 29) | (1 << CGEventType.scrollWheel.rawValue)

        guard let port = CGEvent.tapCreate(
            // The earliest point in the stream, so the gesture is seen even
            // though the window server acts on it too.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            // Listen-only. Swallowing gesture events would take pinch-to-zoom
            // and Mission Control down with them.
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GestureMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        source = runLoopSource
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        reset()
    }

    // MARK: - Detection

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that takes too long in its callback, and
        // re-enabling is the only way back. Cheap insurance for a callback that
        // runs on every scroll event.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let touching = nsEvent.allTouches().filter { $0.phase == .moved || $0.phase == .stationary }

        guard fingerCounts.contains(touching.count) else {
            // Finger lifted or a different count — the gesture is over. Resetting
            // here rather than on `.ended` is what makes a four-finger swipe that
            // briefly reads as three still behave sanely.
            if touching.isEmpty { reset() }
            return
        }

        var travel: CGFloat = 0
        for touch in touching {
            let key = ObjectIdentifier(touch.identity)
            guard let origin = origins[key] else {
                origins[key] = touch.normalizedPosition
                continue
            }
            travel += touch.normalizedPosition.x - origin.x
        }

        guard !hasFired, !origins.isEmpty else { return }
        let average = travel / CGFloat(origins.count)
        guard abs(average) >= travelThreshold else { return }

        hasFired = true
        // Swiping left pushes the content left and brings the next group in from
        // the right — the same sense as the Spaces gesture it replaces.
        onSwipe?(average < 0 ? .next : .previous)
    }

    private func reset() {
        origins.removeAll()
        hasFired = false
    }
}
