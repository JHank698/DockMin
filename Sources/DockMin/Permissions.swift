import AppKit
import ApplicationServices
import CoreGraphics

/// Detects / requests the two system permissions the tool needs.
final class Permissions {
    /// Accessibility — needed to read Dock frames and drive window state via AX.
    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Input Monitoring — needed for the global CGEventTap to observe clicks.
    var inputMonitoringGranted: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightListenEventAccess()
        }
        return true
    }

    var ready: Bool { accessibilityGranted && inputMonitoringGranted }

    /// Prompts for Accessibility (adds the app to the list). Returns the new state.
    @discardableResult
    func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Prompts for Input Monitoring. Returns the new state.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        if #available(macOS 10.15, *) {
            CGRequestListenEventAccess()
        }
        return inputMonitoringGranted
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
