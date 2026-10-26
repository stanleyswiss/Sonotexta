import AVFoundation
import Foundation

/// Normalizes microphone-array buffers before sample-rate conversion.
///
/// FaceTime can change the built-in microphone from a one-channel processed
/// route to a three-channel route without usable channel-layout metadata.
/// Asking AVAudioConverter to implicitly downmix that buffer can cancel speech.
/// Select the strongest real channel explicitly instead, and retain enough
/// energy telemetry to distinguish a bad mix from genuinely zero-filled input.
final class MicrophoneInputNormalizer {
    private let lock = NSLock()
    private let logLabel: String
    private var totalMultichannelFrames = 0
    private var framesAtLastLog = 0
    private var sampleRate: Double = 0
    private var channelCount = 0
    private var maximumPeaks = [Float]()

    init(logLabel: String) {
        self.logLabel = logLabel
    }

    func reset() {
        lock.withLock {
            totalMultichannelFrames = 0
            framesAtLastLog = 0
            sampleRate = 0
            channelCount = 0
            maximumPeaks = []
        }
    }

    /// A visible final-session diagnostic for a multichannel route that
    /// delivered digital silence for at least half a second.
    var captureIssue: String? {
        lock.withLock {
            guard channelCount > 1, sampleRate > 0,
                  Double(totalMultichannelFrames) >= sampleRate * 0.5,
                  (maximumPeaks.max() ?? 0) < 0.000_001 else { return nil }
            return "The microphone delivered only silence on its \(channelCount)-channel call route. Try another input device or end the FaceTime call."
        }
    }

    func normalize(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard input.frameLength > 0, input.format.sampleRate > 0,
              input.format.channelCount > 0 else {
            throw NormalizationError.invalidFormat
        }

        let channels = Int(input.format.channelCount)
        guard channels > 1 else { return input }
        guard input.format.commonFormat == .pcmFormatFloat32,
              let source = input.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: input.format.sampleRate,
                                             channels: 1,
                                             interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                            frameCapacity: input.frameLength),
              let destination = output.floatChannelData?[0] else {
            throw NormalizationError.unsupportedMultichannelFormat
        }

        let frames = Int(input.frameLength)
        let interleaved = input.format.isInterleaved
        var sums = [Double](repeating: 0, count: channels)
        var peaks = [Float](repeating: 0, count: channels)

        for channel in 0..<channels {
            for frame in 0..<frames {
                let sample = interleaved
                    ? source[0][frame * channels + channel]
                    : source[channel][frame]
                sums[channel] += Double(sample) * Double(sample)
                peaks[channel] = max(peaks[channel], abs(sample))
            }
        }

        let rms = sums.map { Float(sqrt($0 / Double(frames))) }
        let selectedChannel = rms.indices.max(by: { rms[$0] < rms[$1] }) ?? 0
        for frame in 0..<frames {
            destination[frame] = interleaved
                ? source[0][frame * channels + selectedChannel]
                : source[selectedChannel][frame]
        }
        output.frameLength = input.frameLength

        let shouldLog = lock.withLock { () -> Bool in
            if channelCount != channels || sampleRate != input.format.sampleRate {
                channelCount = channels
                sampleRate = input.format.sampleRate
                maximumPeaks = [Float](repeating: 0, count: channels)
                totalMultichannelFrames = 0
                framesAtLastLog = 0
            }
            totalMultichannelFrames += frames
            for channel in 0..<channels {
                maximumPeaks[channel] = max(maximumPeaks[channel], peaks[channel])
            }
            if framesAtLastLog == 0 || totalMultichannelFrames - framesAtLastLog >= Int(sampleRate) {
                framesAtLastLog = totalMultichannelFrames
                return true
            }
            return false
        }

        if shouldLog {
            let rmsText = rms.map { String(format: "%.6f", $0) }.joined(separator: ",")
            let peakText = peaks.map { String(format: "%.6f", $0) }.joined(separator: ",")
            print("[Sonotexta][\(logLabel)-channels] input=\(Int(input.format.sampleRate))Hz×\(channels)ch selected=\(selectedChannel) rms=[\(rmsText)] peak=[\(peakText)]")
        }

        return output
    }

    enum NormalizationError: LocalizedError {
        case invalidFormat
        case unsupportedMultichannelFormat

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "The microphone returned an invalid audio format."
            case .unsupportedMultichannelFormat:
                return "The microphone's multichannel format could not be normalized safely."
            }
        }
    }
}

/// Stateful PCM conversion preserves duration at fractional input rates (44.1 kHz)
/// and downmixes channels. One instance belongs to one installed capture tap.
/// See Apple TN3136: rate conversion requires the input-block converter API.
final class LocalAudioResampler {
    private let lock = NSLock()
    private let inputNormalizer: MicrophoneInputNormalizer
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false)!

    init(logLabel: String = "local-audio") {
        inputNormalizer = MicrophoneInputNormalizer(logLabel: logLabel)
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> [Float] {
        try lock.withLock {
            guard input.frameLength > 0 else { return [] }
            let normalized = try inputNormalizer.normalize(input)
            guard normalized.format.sampleRate > 0, normalized.format.channelCount > 0 else {
                throw ConversionError.invalidFormat
            }
            if inputFormat != normalized.format {
                converter = AVAudioConverter(from: normalized.format, to: outputFormat)
                converter?.primeMethod = .none
                inputFormat = normalized.format
            }
            guard let converter else { throw ConversionError.invalidFormat }
            let capacity = AVAudioFrameCount(ceil(Double(normalized.frameLength) * 16_000 / normalized.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw ConversionError.invalidFormat
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return normalized
            }
            if let error { throw error }
            guard status != .error, let samples = output.floatChannelData?[0] else {
                throw ConversionError.invalidFormat
            }
            return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        }
    }

    enum ConversionError: LocalizedError {
        case invalidFormat
        var errorDescription: String? { "The microphone audio format could not be converted to 16 kHz." }
    }
}
