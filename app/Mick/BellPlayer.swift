import AppKit
import MickCore

/// Plays Mick's bell (SPEC §6.5): the original ding synthesized by `BellSound`. The
/// engine decides when (a panel appears and the bell is on); this only makes the noise.
/// Playing a sound never activates the app or takes focus.
@MainActor
final class BellPlayer {
    private let sound: NSSound?
    /// Every play, for the smoke check.
    private(set) var playCount = 0

    /// - Parameter muted: plays at zero volume (the unattended smoke check).
    init(muted: Bool = false) {
        sound = NSSound(data: BellSound.wav())
        sound?.volume = muted ? 0 : 1
    }

    var isLoaded: Bool { sound != nil }

    func play() {
        playCount += 1
        guard let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
