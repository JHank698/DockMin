import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ServiceManagement
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let frontOnlyKey = "minimizeFrontOnly"

    // An LSUIElement app has no window to complain from, so the interesting
    // state goes to the unified log:
    //     log show --last 5m --predicate 'process == "DockMin"'
    private let log = Logger(subsystem: "com.local.dockmin", category: "state")

    private var statusItem: NSStatusItem!

    private let permissions = Permissions()
    private let tap = EventTap()
    private let inspector = DockInspector()
    private let minimizer = AppMinimizer()

    // Baseline captured on mouse-down (before the system handles the click).
    private var baselineApp: NSRunningApplication?
    private var downLocation: CGPoint?
    private var downTime: CFTimeInterval = 0
    /// Window state of the icon under the cursor, read *before* the click
    /// lands. The Dock restores minimized windows while handling mouse-down,
    /// so by mouse-up the app looks "has visible windows" either way — only the
    /// pre-click read can tell a collapse from a bring-them-back.
    private var downTargetPid: pid_t?
    private var downCollapsed: Bool?
    /// The app we collapsed last, so the next click still knows to undo it even
    /// when the pre-click read lost the race against the Dock's own restore.
    private var lastCollapsedPid: pid_t?

    // Menu state.
    private var minimizeFrontOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.frontOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.frontOnlyKey) }
    }
    private var lastA11y: Bool?
    private var lastInput: Bool?
    private var lastFrontOnly: Bool?
    private var lastLogin: Bool?
    private var loggedState: String?

    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        logState()

        // Surface the permission prompts up front.
        permissions.requestAccessibility()
        permissions.requestInputMonitoring()
        startTapIfReady()
        rebuildMenu(force: true)
        logState()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)

        registerLaunchAtLoginIfNeeded()
    }

    /// One line per state change: what *this* process (not whatever launched a
    /// shell copy of it) actually gets from TCC.
    private func logState() {
        let state = "a11y=\(permissions.accessibilityGranted) "
            + "input=\(permissions.inputMonitoringGranted) "
            + "tap=\(tap.isRunning) "
            + "frontOnly=\(minimizeFrontOnly)"
        guard state != loggedState else { return }
        loggedState = state
        log.log("\(state, privacy: .public)")
    }

    // MARK: - Click handling

    private func startTapIfReady() {
        guard permissions.inputMonitoringGranted else { return }
        if !tap.isRunning {
            tap.onEvent = { [weak self] type, location in
                self?.handle(type: type, location: location)
            }
            tap.start()
        }
    }

    private func tick() {
        if permissions.inputMonitoringGranted && !tap.isRunning {
            startTapIfReady()
        }
        logState()
        updateIcon()
        rebuildMenu()
    }

    private func handle(type: CGEventType, location: CGPoint) {
        switch type {
        case .leftMouseDown:
            baselineApp = NSWorkspace.shared.frontmostApplication
            downLocation = location
            downTime = CACurrentMediaTime()
            snapshot(at: location)

        case .leftMouseUp:
            defer { baselineApp = nil; downLocation = nil; downTargetPid = nil; downCollapsed = nil }
            guard let down = downLocation else { return }

            // Must be a genuine click, not a drag or a long press.
            guard hypot(location.x - down.x, location.y - down.y) < 8 else { return }
            guard CACurrentMediaTime() - downTime < 0.6 else { return }

            guard let app = inspector.app(forClickAt: location) else { return }

            // Press and release have to be on the same icon.
            if let pid = downTargetPid, pid != app.processIdentifier { return }

            // Act only when the clicked app was the frontmost app at press
            // time — i.e. the user clicked an already-active app. Otherwise the
            // click targets a background app and the system activates it.
            guard let baseline = baselineApp,
                  baseline.processIdentifier == app.processIdentifier else { return }

            toggle(app)

        default:
            break
        }
    }

    /// Reads the icon under the cursor before the system acts on the press.
    private func snapshot(at location: CGPoint) {
        guard let app = inspector.app(forClickAt: location) else {
            downTargetPid = nil
            downCollapsed = nil
            return
        }
        downTargetPid = app.processIdentifier
        downCollapsed = minimizer.isCollapsed(app)
    }

    /// Windows-style taskbar toggle for the app that is already active:
    /// collapse its windows into the Dock, or bring them back if that is what
    /// the previous click did.
    private func toggle(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"

        // "We collapsed this app last" is the deterministic signal; the pre-click
        // read covers windows the user stowed by hand (Cmd+M). Either one means
        // this click is meant to bring them back — and the pre-click read alone
        // is not enough, because the Dock can restore the windows before our
        // mouse-down handler runs, making it look like nothing was stowed.
        let collapsedBefore = lastCollapsedPid == pid || (downCollapsed ?? false)

        if collapsedBefore {
            // A click on a background app's icon lets the Dock restore the
            // windows by itself; this covers the case where nothing else does.
            let n = minimizer.restore(app)
            lastCollapsedPid = nil
            log.log("click \(name, privacy: .public): restore \(n) (\(n == 0 ? "Dock already did it" : "by us", privacy: .public))")
        } else {
            let scope: AppMinimizer.Scope = minimizeFrontOnly ? .frontmost : .all
            let n = minimizer.minimize(app, scope: scope)
            lastCollapsedPid = n > 0 ? pid : nil
            log.log("click \(name, privacy: .public): minimize \(n) (\(scope == .all ? "all" : "front only", privacy: .public))")
        }
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // `init(systemSymbolName:accessibilityDescription:)` is failable. With a
        // nil image *and* imageOnly *and* an empty title the item collapses to
        // zero width — invisible, not "crowded out" — so the title is the
        // backstop whenever the symbol is missing.
        let image = NSImage(
            systemSymbolName: "rectangle.on.rectangle.angled",
            accessibilityDescription: "DockMin"
        )
        if let image {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageOnly
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "DockMin"
            log.log("status item: SF Symbol missing, using a text title")
        }

        updateIcon()
        rebuildMenu(force: true)
        // The button has no window frame yet at this point, so read it once the
        // status bar has laid the item out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.logGeometry()
        }
    }

    private func logGeometry() {
        let frame = statusItem.button?.frame ?? .zero
        // The button's frame is local to its own window; the *window's* frame is
        // in screen coordinates, which is what says where the icon really went.
        let windowFrame = statusItem.button?.window?.frame ?? .zero
        let screens = NSScreen.screens
            .map { String(format: "[%.0fx%.0f@%.0f,%.0f]", $0.frame.width, $0.frame.height,
                                            $0.frame.minX, $0.frame.minY) }
            .joined()
        let menuBarHeight = NSScreen.main.map { String(format: "%.0f", $0.frame.height - $0.visibleFrame.height) } ?? "?"
        let geometry = String(
            format: "visible=%d length=%.0f frame=%.0fx%.0f window=%.0fx%.0f@%.0f,%.0f image=%d screens=%@ menuBarΔ=%@",
            statusItem.isVisible ? 1 : 0,
            statusItem.length,
            frame.width, frame.height,
            windowFrame.width, windowFrame.height, windowFrame.minX, windowFrame.minY,
            statusItem.button?.image != nil ? 1 : 0,
            screens, menuBarHeight
        )
        log.log("status item: \(geometry, privacy: .public)")
    }

    /// Default (appearance-adaptive) rendering while running; red only when
    /// something is missing. Tinting a template image green/yellow makes it
    /// nearly invisible on a light menu bar — which reads as "no icon at all".
    private func updateIcon() {
        let ready = permissions.ready && tap.isRunning
        let button = statusItem.button
        button?.contentTintColor = ready ? nil : .systemRed
        button?.toolTip = ready
            ? "DockMin 运行中"
            : "DockMin 需要授权（辅助功能 / 输入监控）"
    }

    private func rebuildMenu(force: Bool = false) {
        let a11y = permissions.accessibilityGranted
        let input = permissions.inputMonitoringGranted
        let login = isLoginEnabled

        if !force,
            a11y == lastA11y, input == lastInput,
            minimizeFrontOnly == lastFrontOnly, login == lastLogin {
            return
        }
        lastA11y = a11y; lastInput = input
        lastFrontOnly = minimizeFrontOnly; lastLogin = login

        let needsPermission = !(a11y && input)
        let menu = NSMenu()

        let status = NSMenuItem(
            title: needsPermission ? "DockMin — 需要授权" : "DockMin — 运行中",
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addInfo(menu, "辅助功能：\(a11y ? "已授权" : "未授权")")
        addInfo(menu, "输入监控：\(input ? "已授权" : "未授权")")

        if needsPermission {
            menu.addItem(.separator())
            addAction(menu, "请求辅助功能授权", #selector(requestAccessibility))
            addAction(menu, "请求输入监控授权", #selector(requestInputMonitoring))
            addAction(menu, "打开系统设置", #selector(openRelevantSettings))
        }

        menu.addItem(.separator())
        addToggle(menu, "仅最小化最前窗口", #selector(toggleFrontOnly), on: minimizeFrontOnly)
        addToggle(menu, "登录时启动", #selector(toggleLogin), on: login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 DockMin", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ selector: Selector, on: Bool) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    // MARK: - Menu actions

    @objc private func requestAccessibility() {
        permissions.requestAccessibility()
        rebuildMenu(force: true)
    }

    @objc private func requestInputMonitoring() {
        permissions.requestInputMonitoring()
        // A tap created before authorization sticks in its ungranted state;
        // build a fresh one once the permission shows up.
        if permissions.inputMonitoringGranted, tap.isRunning {
            tap.rearm()
        }
        startTapIfReady()
        updateIcon()
        rebuildMenu(force: true)
    }

    @objc private func openRelevantSettings() {
        if !permissions.accessibilityGranted {
            permissions.openAccessibilitySettings()
        } else if !permissions.inputMonitoringGranted {
            permissions.openInputMonitoringSettings()
        }
    }

    @objc private func toggleFrontOnly() {
        minimizeFrontOnly.toggle()
        rebuildMenu(force: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Launch at login

    private var isLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin() {
        do {
            if isLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("DockMin: launch-at-login toggle failed: \(error)")
        }
        rebuildMenu(force: true)
    }

    private func registerLaunchAtLoginIfNeeded() {
        guard !isLoginEnabled else { return }
        do {
            try SMAppService.mainApp.register()
            NSLog("DockMin: registered launch-at-login")
        } catch {
            NSLog("DockMin: could not register launch-at-login: \(error)")
        }
    }
}
