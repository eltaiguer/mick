import AppKit

// Mick: a menu bar agent (LSUIElement, no Dock icon) with its own NSStatusItem.
// No SwiftUI App / MenuBarExtra (SPEC §9.3, decision 22).

let options: LaunchOptions
do {
    options = try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("Mick: \(error)\n".utf8))
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
