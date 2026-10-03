import AppKit
import CoreGraphics
import Foundation

/// A global, **listen-only** mouse event tap.
///
/// It observes left-mouse down/up at the session level and forwards
/// `(type, location)` on the main queue. Because it is listen-only the events
/// always pass through untouched, so normal Dock activation still happens; the
/// caller decides whether to additionally minimize.
final class EventTap {
    var onEvent: ((CGEventType, CGPoint) -> Void)?

    // `CGEventTapCreate` hands back a mach port; there is no distinct
    // `CGEventTap` type in the SDK headers.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isRunning = false

    private static let mask: CGEventMask =
        (CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)) |
        (CGEventMask(1) << CGEventMask(CGEventType.leftMouseUp.rawValue))

    /// Creates and arms the tap. No-op if it is already running.
    func start() {
        guard !isRunning else { return }

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let self_ = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

            // The system disables taps that block the input stream; re-arm ours.
            // `proxy` is only a context pointer — re-enabling needs our own port.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                self_.reenable()
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            DispatchQueue.main.async { self_.onEvent?(type, location) }
            // listen-only: always let the event continue.
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            // Usually means Input Monitoring isn't granted yet.
            NSLog("DockMin: CGEventTap creation failed (Input Monitoring not granted?)")
            return
        }

        tap = t
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
        CGEvent.tapEnable(tap: t, enable: true)
        isRunning = true
    }

    /// Tears the tap down and starts a fresh one (after a permission change).
    func rearm() {
        teardown()
        start()
    }

    private func reenable() {
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardown() {
        isRunning = false
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
    }

    deinit {
        teardown()
    }
}
