import AppKit
import ApplicationServices
import CoreGraphics

/// Maps a click point on screen to the running application whose Dock icon
/// contains that point, by reading the Dock's accessibility element tree.
final class DockInspector {
    /// Returns the running app whose Dock icon contains `point`, or nil.
    func app(forClickAt point: CGPoint) -> NSRunningApplication? {
        guard let pid = dockPID(),
              let tile = dockTile(containing: point, dockPID: pid),
              let title = string(tile, kAXTitleAttribute) else { return nil }

        return match(title: title)
    }

    // MARK: - Dock enumeration

    private func dockPID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.dock" }?
            .processIdentifier
    }

    /// Hit-tests `point` against the frames of every titled element in the
    /// Dock tree and returns the tightest tile that contains it.
    ///
    /// The Dock's internal role/subrole naming and nesting are undocumented and
    /// have shifted across macOS versions, so rather than trusting them this
    /// walks the tree for anything with a title and a frame, then lets geometry
    /// decide: the individual icon always beats the enclosing list. Subrole is
    /// only used to prefer genuine app tiles when several frames tie.
    private func dockTile(containing point: CGPoint, dockPID pid: pid_t) -> AXUIElement? {
        let tiles = collectTiles(dockPID: pid)

        // Small expansion so clicks near an icon edge still register.
        let pad: CGFloat = -4
        let hits = tiles.filter { $0.frame.insetBy(dx: pad, dy: pad).contains(point) }
        guard let best = hits.min(by: { a, b in
            // A recognised app tile beats an enclosing container; among equals
            // the tightest frame is the icon actually under the cursor.
            if a.isAppTile != b.isAppTile { return a.isAppTile && !b.isAppTile }
            return a.frame.area < b.frame.area
        }) else { return nil }

        // A hit far larger than the smallest one is a container (the Dock's
        // list or an application group), not an icon.
        if let smallest = hits.map({ $0.frame.area }).min(), best.frame.area > smallest * 4 {
            return nil
        }
        return best.element
    }

    /// Every titled, framed element in the Dock tree — used by the `--dump-dock`
    /// diagnostics to show what the hit-test is working from.
    func dumpTiles() -> [TileInfo] {
        guard let pid = dockPID() else { return [] }
        return collectTiles(dockPID: pid).map {
            TileInfo(title: $0.title, subrole: $0.subrole, frame: $0.frame, isAppTile: $0.isAppTile)
        }
    }

    struct TileInfo {
        let title: String
        let subrole: String
        let frame: CGRect
        let isAppTile: Bool
    }

    private struct Tile {
        let element: AXUIElement
        let title: String
        let subrole: String
        let frame: CGRect
        let isAppTile: Bool
    }

    private func collectTiles(dockPID pid: pid_t) -> [Tile] {
        var tiles: [Tile] = []
        collectTiles(in: AXUIElementCreateApplication(pid), depth: 0, into: &tiles)
        return tiles
    }

    private func collectTiles(in node: AXUIElement, depth: Int, into out: inout [Tile]) {
        guard depth <= 8 else { return }

        let subrole = string(node, kAXSubroleAttribute) ?? ""
        if subrole != "AXTrashDockItem", subrole != "AXOtherDockItem",
           let title = string(node, kAXTitleAttribute), !title.isEmpty,
           let origin = point(node, kAXPositionAttribute),
           let size = size(node, kAXSizeAttribute), size.width > 1, size.height > 1 {
            out.append(
                Tile(
                    element: node,
                    title: title,
                    subrole: subrole,
                    frame: CGRect(origin: origin, size: size),
                    isAppTile: subrole.isEmpty || subrole.contains("ApplicationDockItem")
                )
            )
        }

        guard let kids = children(node) else { return }
        for k in kids { collectTiles(in: k, depth: depth + 1, into: &out) }
    }

    // MARK: - Title → application

    /// Dock tiles show the app's display name; match it against the running
    /// apps, tolerating case differences and the `.app` suffix.
    private func match(title: String) -> NSRunningApplication? {
        let needle = normalize(title).lowercased()
        guard !needle.isEmpty else { return nil }

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }

        for app in apps {
            if let name = app.localizedName, normalize(name).lowercased() == needle { return app }
        }
        for app in apps {
            guard let url = app.bundleURL?.deletingPathExtension().lastPathComponent else { continue }
            if normalize(url).lowercased() == needle { return app }
        }
        return nil
    }

    private func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - AX readers

    // The AX attribute constants arrive in Swift as `String`, so the key is
    // bridged here rather than at every call site.
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &v) == .success else { return nil }
        return v
    }

    private func string(_ element: AXUIElement, _ key: String) -> String? {
        value(element, key) as? String
    }

    private func children(_ element: AXUIElement) -> [AXUIElement]? {
        value(element, kAXChildrenAttribute) as? [AXUIElement]
    }

    private func point(_ element: AXUIElement, _ key: String) -> CGPoint? {
        guard let raw = value(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    private func size(_ element: AXUIElement, _ key: String) -> CGSize? {
        guard let raw = value(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &s) else { return nil }
        return s
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
