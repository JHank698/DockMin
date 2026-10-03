import AppKit
import CoreGraphics
import ServiceManagement

/// Shell-invocable diagnostics, so the permission state and the Dock hit-test
/// can be checked without clicking around:
///
///	 DockMin --status              permissions, Dock presence, login item
///	 DockMin --dump-dock           every tile the hit-test sees, with frames
///	 DockMin --hit 123 1080        which app a click at (x, y) maps to
enum Diagnostics {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "--status": return status()
        case "--dump-dock": return dumpDock()
        case "--hit": return hit(args)
        default:
            print("usage: DockMin [--status | --dump-dock | --hit <x> <y>]")
            return 2
        }
    }

    // MARK: - --status

    private static func status() -> Int32 {
        let permissions = Permissions()
        print("Accessibility:    \(permissions.accessibilityGranted ? "granted" : "NOT granted")")
        print("Input Monitoring: \(permissions.inputMonitoringGranted ? "granted" : "NOT granted")")

        let dock = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.dock" }
        print("Dock process:     \(dock.map { "pid \($0.processIdentifier)" } ?? "NOT found")")

        if permissions.accessibilityGranted {
            let tiles = DockInspector().dumpTiles()
            print("Dock tiles:        \(tiles.count) titled elements")
        } else {
            print("Dock tiles:        (needs Accessibility)")
        }

        let login = SMAppService.mainApp.status
        print("Launch at login:  \(describe(login))")

        if permissions.ready {
            print("READY")
            return 0
        }
        // A shell-spawned copy is not the same TCC client as the app the user
        // launched: macOS can attribute this call to the hosting terminal.
        print("NOT READY — note: run from a shell this process's permissions may be")
        print("attributed to the terminal app, not to DockMin.app. Trust the app's own")
        print("reading instead:")
        print("  /usr/bin/log show --last 5m --predicate \\(quoted)")
        return 1
    }

    private static let quoted = "'process == \"DockMin\" AND subsystem == \"com.local.dockmin\"'"

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "enabled, awaiting user approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found (run from a signed .app bundle)"
        @unknown default: return "unknown"
        }
    }

    // MARK: - --dump-dock

    private static func dumpDock() -> Int32 {
        let tiles = DockInspector().dumpTiles()
        if tiles.isEmpty {
            print("no Dock tiles visible — is Accessibility granted to this binary?")
            return 1
        }
        for tile in tiles {
            let kind = tile.isAppTile ? "app " : "other"
            print("\(kind) | \(tile.subrole.isEmpty ? "-" : tile.subrole) | \(tile.frame) | \(tile.title)")
        }
        return 0
    }

    // MARK: - --hit

    private static func hit(_ args: [String]) -> Int32 {
        guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
            print("usage: DockMin --hit <x> <y>")
            return 2
        }
        let point = CGPoint(x: x, y: y)
        guard let app = DockInspector().app(forClickAt: point) else {
            print("no app for click at \(point)")
            return 1
        }
        print("\(app.localizedName ?? "?") — pid \(app.processIdentifier), \(app.bundleIdentifier ?? "?")")
        return 0
    }
}
