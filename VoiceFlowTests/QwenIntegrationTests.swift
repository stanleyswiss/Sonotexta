import Foundation
import Testing
@testable import Sonotexta

struct QwenIntegrationTests {
    @Test func chunksCoverLongDictationWithoutGapsOrDuplicates() {
        let samples = [Float](repeating: 0.2, count: 65 * QwenAudioChunks.sampleRate + 137)
        let ranges = QwenAudioChunks.ranges(in: samples)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == samples.count)
        #expect(ranges.reduce(0) { $0 + $1.count } == samples.count)
        for (index, range) in ranges.enumerated() {
            #expect(!range.isEmpty)
            #expect(range.count <= QwenAudioChunks.maximumSamples)
            if index > 0 { #expect(ranges[index - 1].upperBound == range.lowerBound) }
        }
    }

    @Test func chunksPreferPauseAndKeepShortTail() {
        var samples = [Float](repeating: 0.2, count: 13 * QwenAudioChunks.sampleRate)
        let pause = 11 * QwenAudioChunks.sampleRate
        samples.replaceSubrange(pause..<(pause + 1600), with: repeatElement(Float(0), count: 1600))
        let ranges = QwenAudioChunks.ranges(in: samples)
        #expect(ranges.first?.upperBound == pause + 800)
        #expect(ranges.last?.upperBound == samples.count)
        #expect(QwenAudioChunks.ranges(in: []).isEmpty)
        #expect(QwenAudioChunks.ranges(in: [0.1]) == [0..<1])
    }

    @Test @MainActor func customStorageAndLocalCatalog() {
        let root = URL(fileURLWithPath: "/Volumes/Models/Sonotexta", isDirectory: true)
        #expect(QwenEngine.modelDirectory(customRoot: root).path == "/Volumes/Models/Sonotexta/FluidAudio/Models/qwen3-asr-0.6b-coreml/f32")
        #expect(STTEngineType.qwen.requiresDownload)
        #expect(!STTEngineType.qwen.isCloudStreaming)
        #expect(STTEngineType(rawValue: "qwen3_asr") == .qwen)
    }

    @Test @MainActor func directoryWithoutCompletedLoadIsNotReady() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!QwenEngine.isReady(at: root))
        try Data("ready".utf8).write(to: root.appendingPathComponent(".sonotexta-qwen-ready"))
        #expect(!QwenEngine.isReady(at: root))
    }

    @Test func stoppedCaptureRejectsLateAudioAndPreservesColdStartSamples() {
        let captured = QwenCaptureBuffer()
        captured.begin()
        captured.append([0.1, 0.2])
        captured.pause()
        captured.append([0.3])
        #expect(captured.take().0 == [0.1, 0.2])
        #expect(captured.take().0.isEmpty)
    }

    @Test func captureFailureSurvivesPauseAndResetsOnNextSession() {
        let captured = QwenCaptureBuffer()
        captured.begin()
        captured.fail(QwenEngineError.captureInterrupted)
        captured.pause()
        #expect(captured.take().1 != nil)
        captured.begin()
        #expect(captured.isActive)
        #expect(captured.take().1 == nil)
    }
}
