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
