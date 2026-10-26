import AVFoundation
import Foundation
import Testing
@testable import Sonotexta

/// Explicit opt-in: downloads the actual model and the public JFK speech fixture from whisper.cpp.
/// Ordinary unit-test runs remain offline and never access the microphone.
struct QwenInferenceSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SONOTEXTA_RUN_QWEN_SMOKE"] == "1"))
    @MainActor func transcribesRealSpeechWithDownloadedModel() async throws {
        let engine = QwenEngine()
        try await engine.loadModel()
        #expect(QwenEngine.isDownloaded)
        let url = URL(string: "https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/samples/jfk.wav")!
        let (download, response) = try await URLSession.shared.download(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        defer { try? FileManager.default.removeItem(at: download) }
        let audioFile = try AVAudioFile(forReading: download)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(audioFile.length)))
        try audioFile.read(into: buffer)
        let samples = try LocalAudioResampler().convert(buffer)
        #expect(!samples.isEmpty)
        let transcript = try await engine.transcribe(samples: samples, language: "en")
        #expect(transcript.lowercased().contains("country"))
        // Repeat actual recorded speech to exercise the >30-second chunk path.
        let longSamples = Array(repeating: samples, count: 4).flatMap { $0 }
        let longTranscript = try await engine.transcribe(samples: longSamples, language: "en")
        #expect(longSamples.count > 30 * QwenAudioChunks.sampleRate)
        #expect(longTranscript.lowercased().components(separatedBy: "country").count >= 5)
        let report: [String: Any] = [
            "source": url.absoluteString,
            "sampleCount": samples.count,
            "chunks": QwenAudioChunks.ranges(in: samples).count,
            "transcript": transcript,
            "longSampleCount": longSamples.count,
            "longChunks": QwenAudioChunks.ranges(in: longSamples).count,
            "longTranscript": longTranscript,
            "modelDirectory": QwenEngine.modelDirectory(customRoot: ModelStorage.customRoot).path
        ]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sonotexta-qwen-smoke.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("[Qwen smoke] \(output.path): \(transcript)")
    }
}
