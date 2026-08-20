import AppKit
import ApplicationServices

/// Maps an Accessibility window element to the `CGWindowID` the window server
/// uses. Private, but stable for over a decade and the only way to bridge the
/// two APIs — DockDoor and AeroSpace rely on the same symbol.
///
/// The CGWindowID is what gives a window a stable identity for group membership.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {

    /// Not exported as a constant by ApplicationServices, but a long-standing
    /// documented attribute. This is what separates a genuinely fullscreen
    /// window — its own Space, menu bar hidden — from one merely zoomed to fill
    /// the screen. The two are nearly identical by geometry and need opposite
    /// treatment, so geometry is never used to decide it.
    static let fullScreenAttribute = "AXFullScreen"

    /// Seconds any one Accessibility round-trip may take before it gives up.
    /// A healthy application answers in well under a millisecond, so this only
    /// ever binds on one that is genuinely stuck.
    static let messagingTimeout: Float = 0.5

    /// Bounds every Accessibility round-trip this process makes.
    ///
    /// Each AX call is synchronous IPC into another process, and a full window
    /// sweep makes hundreds of them on the main thread. With no timeout set they
    /// use the system default, which is measured in *seconds* — so one
    /// application that is busy, swapping or midway through quitting parks the
    /// main thread, and with it the strip, the hotkeys and every timer.
    ///
    /// Measured: a 25-second stall, which appeared in the log only as a perf
    /// heartbeat arriving 85s after the previous one instead of 60. Flat CPU
    /// across the gap is the tell — the thread was blocked in `mach_msg`, not
    /// busy — and it is the same blocked-leaf signature that made the engine
    /// tick look expensive in a `sample` profile when it was mostly waiting.
    ///
    /// The timeout set on the system-wide element becomes the default for every
    /// element that has none of its own, so this one call covers the sweep, the
    /// zoom clamp, the fullscreen probe and raising a window alike.
    static func boundMessagingTimeouts() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        value(element, attribute) ?? false
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ newValue: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, newValue as CFBoolean)
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw) == .success,
              let axValue = raw, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw) == .success,
              let axValue = raw, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func setSize(_ element: AXUIElement, _ newSize: CGSize) {
        var size = newSize
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    static func perform(_ element: AXUIElement, _ action: String) {
        AXUIElementPerformAction(element, action as CFString)
    }
}
