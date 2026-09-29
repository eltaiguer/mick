import Foundation

/// Mick's bell (SPEC §6.5, decision 13): an original boxing-bell style ding,
/// synthesized here rather than sampled, so there's no borrowed audio anywhere. A few
/// inharmonic partials (the metallic part), each with its own exponential decay, a
/// slightly detuned twin of the fundamental for shimmer, and a short hammer click.
/// Rendered as 16-bit mono PCM in a WAV container that `NSSound(data:)` plays.
public enum BellSound {
    public static let sampleRate = 44_100
    public static let duration: Double = 1.6
    /// The loudest sample, as a fraction of full scale. Leaves headroom.
    public static let peak: Double = 0.6

    struct Partial {
        var frequency: Double
        var amplitude: Double
        /// Seconds for the partial to fall to 1/e.
        var decay: Double
    }

    static let fundamental: Double = 784  // around G5: bright, cuts through without shrieking
    static let partials: [Partial] = [
        Partial(frequency: fundamental, amplitude: 1.0, decay: 0.9),
        Partial(frequency: fundamental * 1.004, amplitude: 0.5, decay: 0.8),
        Partial(frequency: fundamental * 2.01, amplitude: 0.45, decay: 0.55),
        Partial(frequency: fundamental * 2.76, amplitude: 0.4, decay: 0.4),
        Partial(frequency: fundamental * 4.07, amplitude: 0.22, decay: 0.25),
        Partial(frequency: fundamental * 5.40, amplitude: 0.12, decay: 0.15),
    ]

    /// The samples, in -1...1.
    public static func samples() -> [Double] {
        let count = Int(duration * Double(sampleRate))
        var out = [Double](repeating: 0, count: count)
        var noise: UInt32 = 0x6D69_636B  // "mick": a fixed seed, so every ding is the same
        let clickSamples = Int(0.004 * Double(sampleRate))
        let fadeSamples = Int(0.08 * Double(sampleRate))
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            var v = 0.0
            for p in partials {
                v += p.amplitude * exp(-t / p.decay) * sin(2 * .pi * p.frequency * t)
            }
            // A 1 ms attack so the strike doesn't pop.
            v *= min(1, t / 0.001)
            if i < clickSamples {
                noise = noise &* 1_664_525 &+ 1_013_904_223
                let white = Double(noise >> 8) / Double(1 << 24) * 2 - 1
                v += 0.6 * white * (1 - Double(i) / Double(clickSamples))
            }
            if i >= count - fadeSamples {
                v *= Double(count - i) / Double(fadeSamples)
            }
            out[i] = v
        }
        let loudest = out.map(abs).max() ?? 1
        let scale = loudest > 0 ? peak / loudest : 0
        return out.map { $0 * scale }
    }

    /// A complete WAV file (RIFF, PCM, 16-bit, mono).
    public static func wav() -> Data {
        let pcm = samples().map { Int16(($0 * Double(Int16.max)).rounded()) }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytesPerSample = 2
        let dataBytes = pcm.count * bytesPerSample
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                 // fmt chunk size
        append(UInt16(1))                  // PCM
        append(UInt16(1))                  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))  // byte rate
        append(UInt16(bytesPerSample))     // block align
        append(UInt16(16))                 // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        for sample in pcm { append(sample) }
        return data
    }
}
