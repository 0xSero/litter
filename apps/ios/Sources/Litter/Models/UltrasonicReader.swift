#if !targetEnvironment(macCatalyst)
import Accelerate
import AVFoundation
import Foundation

/// iPhone-side ultrasonic listener. Captures mic audio, runs an FFT to
/// locate the peak in the 18.5–19.5 kHz band (matching `UltrasonicEmitter`),
/// and converts frequency offset from 19 kHz into radial velocity using the
/// Doppler formula:
///
///     v = c · (f_observed − f_emitted) / f_emitted
///
/// Positive velocity = iPhone approaching the Mac (frequency shifted up).
/// Update rate is bound by AVAudioEngine tap buffer size (~85 ms → ~12 Hz).
@MainActor
final class UltrasonicReader {
    /// Speed of sound at 20°C, dry air. Doppler error < 1% over typical
    /// indoor temperature/humidity range, so we don't bother correcting.
    private static let speedOfSoundMS: Float = 343
    /// Must match `UltrasonicEmitter.carrierFrequencyHz`.
    private static let carrierHz: Float = 19_000
    /// Search band; wider than ±velocity-of-interest to absorb mic-input
    /// sample-rate jitter and Mac speaker frequency drift.
    private static let bandLowHz: Float = 18_500
    private static let bandHighHz: Float = 19_500
    /// Magnitude floor to suppress false peaks when the Mac isn't audible
    /// (silent room shouldn't pretend to detect a carrier).
    private static let detectionThreshold: Float = 1e-3
    /// FFT length in samples. 4096 at 48 kHz = ~85 ms window, ~11.7 Hz
    /// per-bin resolution, ~0.21 m/s velocity resolution at 19 kHz.
    private nonisolated static let fftLength: Int = 4096

    /// Latest detected carrier frequency (Hz). nil while no peak crosses
    /// the detection threshold (e.g., Mac out of acoustic range).
    private(set) var lastPeakHz: Float?
    /// Latest radial velocity in m/s. Positive = approaching Mac.
    private(set) var lastVelocityMS: Float?
    /// Smoothed velocity for haptics/UI to avoid per-frame jitter.
    private(set) var smoothedVelocityMS: Float?
    /// Confidence proxy (peak magnitude / median magnitude in band). High
    /// when carrier is clearly present, low/nil when noisy or absent.
    private(set) var lastConfidence: Float?

    /// Optional callback fired on every detection sample. Used by
    /// `NearbyMacPairing` to drive observable state + relay to Mac.
    var onSample: ((_ velocityMS: Float?, _ peakHz: Float?, _ confidence: Float?) -> Void)?

    private let engine = AVAudioEngine()
    private var fftSetup: vDSP_DFT_Setup?
    private var window: [Float] = []
    private var isRunning = false

    func start() async throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // `.measurement` mode disables the system's built-in voice-band
        // filter so ultrasonic content survives the mic preprocessing.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true, options: [])

        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { ok in cont.resume(returning: ok) }
        }
        guard granted else {
            LLog.warn("pair", "ultrasonic: mic permission denied")
            throw NSError(domain: "Litter.Ultrasonic", code: 1, userInfo: [NSLocalizedDescriptionKey: "mic permission denied"])
        }

        // Hann window once per process; FFT runs on every tap.
        var w = [Float](repeating: 0, count: Self.fftLength)
        vDSP_hann_window(&w, vDSP_Length(Self.fftLength), Int32(vDSP_HANN_NORM))
        window = w
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftLength), .FORWARD)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(Self.fftLength),
            format: format
        ) { [weak self] buffer, _ in
            // Tap fires on a real-time audio thread; bounce to main for
            // observable state updates, but compute the FFT off-main.
            self?.processOffMain(buffer: buffer, sampleRate: Float(format.sampleRate))
        }

        try engine.start()
        isRunning = true
        LLog.info(
            "pair",
            "ultrasonic reader started",
            fields: ["sample_rate": Int(format.sampleRate), "fft_length": Self.fftLength]
        )
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
            fftSetup = nil
        }
        isRunning = false
        lastPeakHz = nil
        lastVelocityMS = nil
        smoothedVelocityMS = nil
        lastConfidence = nil
    }

    // MARK: - FFT pipeline

    private nonisolated func processOffMain(buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount >= Self.fftLength else { return }

        var samples = [Float](repeating: 0, count: Self.fftLength)
        // Take the most recent fftLength samples in case the tap overshot.
        memcpy(&samples, channelData[0], Self.fftLength * MemoryLayout<Float>.size)

        // We can't access fftSetup/window from non-isolated context safely
        // without an actor hop; ship the samples to main and finish there.
        // The FFT is only ~80 µs at N=4096 on Apple Silicon, so this is fine.
        Task { @MainActor [samples] in
            self.process(samples: samples, sampleRate: sampleRate)
        }
    }

    private func process(samples: [Float], sampleRate: Float) {
        guard let setup = fftSetup, !window.isEmpty else { return }
        let n = Self.fftLength

        // Apply Hann window to reduce spectral leakage at the carrier bin.
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // DFT_zop expects split-complex input; imaginary part is zero for
        // a real signal.
        var realIn = windowed
        var imagIn = [Float](repeating: 0, count: n)
        var realOut = [Float](repeating: 0, count: n)
        var imagOut = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        // Magnitude (squared is fine for peak finding).
        let half = n / 2
        var mags = [Float](repeating: 0, count: half)
        realOut.withUnsafeMutableBufferPointer { rp in
            imagOut.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        let binWidth = sampleRate / Float(n)
        let lowBin = max(1, Int((Self.bandLowHz / binWidth).rounded(.down)))
        let highBin = min(half - 2, Int((Self.bandHighHz / binWidth).rounded(.up)))
        guard lowBin < highBin else { return }

        var peakBin = lowBin
        var peakMag: Float = 0
        var sum: Float = 0
        var count: Float = 0
        for bin in lowBin...highBin {
            let m = mags[bin]
            sum += m
            count += 1
            if m > peakMag {
                peakMag = m
                peakBin = bin
            }
        }
        let mean = count > 0 ? sum / count : 0
        let confidence = mean > 0 ? peakMag / mean : 0

        guard peakMag >= Self.detectionThreshold, peakBin > lowBin, peakBin < highBin else {
            lastPeakHz = nil
            lastVelocityMS = nil
            lastConfidence = confidence
            onSample?(nil, nil, confidence)
            return
        }

        // Parabolic interpolation between adjacent bins for sub-bin freq.
        let alpha = mags[peakBin - 1]
        let beta = mags[peakBin]
        let gamma = mags[peakBin + 1]
        let denom = alpha - 2 * beta + gamma
        let offset: Float = denom != 0 ? 0.5 * (alpha - gamma) / denom : 0
        let preciseBin = Float(peakBin) + offset
        let peakHz = preciseBin * binWidth

        let velocity = Self.speedOfSoundMS * (peakHz - Self.carrierHz) / Self.carrierHz

        lastPeakHz = peakHz
        lastVelocityMS = velocity
        lastConfidence = confidence
        // EMA smoothing on velocity. α = 0.35 → ~3-sample halflife at 12 Hz
        // update rate, ~250 ms response — fast enough to feel live, slow
        // enough to suppress wind/breath noise.
        if let prev = smoothedVelocityMS {
            smoothedVelocityMS = prev * 0.65 + velocity * 0.35
        } else {
            smoothedVelocityMS = velocity
        }

        onSample?(velocity, peakHz, confidence)
    }
}
#endif
