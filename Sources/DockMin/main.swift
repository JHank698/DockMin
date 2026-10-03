import AppKit

// Diagnostics mode: run the same binary from a shell to inspect state.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first?.hasPrefix("--") == true {
    exit(Diagnostics.run(arguments))
}

// Menu-bar agent app: no Dock icon, no main window (LSUIElement in Info.plist).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
