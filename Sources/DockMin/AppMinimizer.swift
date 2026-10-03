import AppKit
import ApplicationServices

/// Drives a running application's windows through the Accessibility API:
/// collapses them into the Dock and brings them back again.
final class AppMinimizer {
    enum Scope {
        /// Collapse the whole app into the Dock (minimize every window).
        case all
        /// Only the currently focused window.
        case frontmost
    }

    /// Minimizes the app's windows. Returns how many windows were minimized.
    @discardableResult
    func minimize(_ app: NSRunningApplication, scope: Scope) -> Int {
        let windows = visibleWindows(of: app)
        guard !windows.isEmpty else { return 0 }

        let targets: [AXUIElement]
        switch scope {
        case .all:
            targets = windows
        case .frontmost:
            guard let focused = focusedWindow(of: app),
                  windows.contains(where: { isSame($0, focused) }) else {
                // Nothing focused (or the focused window is not minimizable):
                // fall back to no-op rather than collapsing every window.
                return 0
            }
            targets = [focused]
        }

        return set(minimized: true, on: targets)
    }

    /// Restores the app's minimized windows. Returns how many were restored.
    @discardableResult
    func restore(_ app: NSRunningApplication) -> Int {
        set(minimized: false, on: minimizedWindows(of: app))
    }

    /// Windows the app currently has on screen (not minimized, not orphaned).
    func visibleWindowCount(of app: NSRunningApplication) -> Int {
        visibleWindows(of: app).count
    }

    /// Windows the app has stowed in the Dock.
    func minimizedWindowCount(of app: NSRunningApplication) -> Int {
        minimizedWindows(of: app).count
    }

    /// True when the app has nothing on screen but still has windows stowed
    /// in the Dock — the state a second click is meant to undo.
    func isCollapsed(_ app: NSRunningApplication) -> Bool {
        visibleWindowCount(of: app) == 0 && minimizedWindowCount(of: app) > 0
    }

    // MARK: - AX plumbing

    private func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = copy(ax, kAXWindowsAttribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func visibleWindows(of app: NSRunningApplication) -> [AXUIElement] {
        windows(of: app).filter { bool($0, kAXMinimizedAttribute) != true }
    }

    private func minimizedWindows(of app: NSRunningApplication) -> [AXUIElement] {
        windows(of: app).filter { bool($0, kAXMinimizedAttribute) == true }
    }

    private func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = copy(ax, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Applies `kAXMinimizedAttribute` to each window, skipping the ones that
    /// are already in the wanted state. Returns the number actually changed.
    private func set(minimized: Bool, on windows: [AXUIElement]) -> Int {
        var changed = 0
        for window in windows {
            if bool(window, kAXMinimizedAttribute) == minimized { continue }
            let value: CFTypeRef = minimized
                ? (kCFBooleanTrue as CFTypeRef)
                : (kCFBooleanFalse as CFTypeRef)
            if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value) == .success {
                changed += 1
            }
        }
        return changed
    }

    private func isSame(_ a: CFTypeRef?, _ b: CFTypeRef?) -> Bool {
        guard let a, let b else { return false }
        return CFEqual(a, b)
    }

    // The AX attribute constants arrive in Swift as `String`, so the key is
    // bridged here rather than at every call site.
    private func copy(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &v) == .success else { return nil }
        return v
    }

    private func bool(_ element: AXUIElement, _ key: String) -> Bool? {
        guard let v = copy(element, key) else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        return v as? Bool
    }
}
