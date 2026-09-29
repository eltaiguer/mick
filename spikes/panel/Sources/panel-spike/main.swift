import AppKit
import PanelSpikeKit

// Spike for SPEC §9.3 items 1-4: a status item and a panel that never takes focus.
// See spikes/panel/README.md.

let options: SpikeOptions
do {
    options = try SpikeOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("panel-spike: \(error)\n\(SpikeOptions.usage)\n".utf8))
    exit(2)
}

let app = NSApplication.shared
let delegate = SpikeAppDelegate(options: options)
app.delegate = delegate
app.run()
