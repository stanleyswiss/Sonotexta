import Testing
import Foundation
import AVFoundation
@testable import Sonotexta

private final class StorageFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sonotexta-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult
    func file(_ path: String, _ text: String = "model data") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
    func pairs() -> [ModelStorageMigration.Pair] {
        ["Whisper", "Parakeet"].map { .init(name: $0, source: url("old/\($0)"), destination: url("new/\($0)")) }
    }
}

struct ModelMigrationRegressionTests {
    @Test func changesMadeAfterCopyAreNotDeletedDuringCleanup() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/model")
        let prepared = try ModelStorageMigration.prepare(pairs: fixture.pairs())
        try fixture.file("old/Whisper/added-later", "new data")
        let summary = prepared.removeOriginals()
        #expect(fixture.exists("old/Whisper/added-later"))
        #expect(fixture.exists("new/Whisper/model"))
        #expect(summary.contains("could not be removed"))
    }

    @Test func invalidCopyNeverPublishesOrRemovesOriginal() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/model")
        #expect(throws: ModelStorageMigration.MigrationError.self) {
            try ModelStorageMigration.prepare(pairs: fixture.pairs(), copy: { _, destination in
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            })
        }
        #expect(fixture.exists("old/Whisper/model"))
        #expect(!fixture.exists("new/Whisper"))
    }

    @Test func secondCopyFailureKeepsBothOriginalFamilies() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/model")
        try fixture.file("old/Parakeet/model")
        var count = 0
        #expect(throws: CocoaError.self) {
            try ModelStorageMigration.prepare(pairs: fixture.pairs(), copy: { source, target in
                count += 1
                if count == 2 { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.copyItem(at: source, to: target)
            })
        }
        #expect(fixture.exists("old/Whisper/model"))
        #expect(fixture.exists("old/Parakeet/model"))
        #expect(!fixture.exists("new/Whisper"))
        #expect(!fixture.exists("new/Parakeet"))
    }

    @Test func failedSecondPublicationRollsBackFirst() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/model")
        try fixture.file("old/Parakeet/model")
        var count = 0
        #expect(throws: CocoaError.self) {
            try ModelStorageMigration.prepare(pairs: fixture.pairs(), publish: { source, target in
                count += 1
                if count == 2 { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.moveItem(at: source, to: target)
            })
        }
        #expect(fixture.exists("old/Whisper/model"))
        #expect(fixture.exists("old/Parakeet/model"))
        #expect(!fixture.exists("new/Whisper"))
    }

    @Test func originalsSurvivePreparationUntilSettingsCommit() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/model")
        let prepared = try ModelStorageMigration.prepare(pairs: fixture.pairs())
        #expect(fixture.exists("old/Whisper/model"))
        #expect(fixture.exists("new/Whisper/model"))
        _ = prepared.removeOriginals()
        #expect(!fixture.exists("old/Whisper"))
        #expect(fixture.exists("new/Whisper/model"))
    }

    @Test func populatedDestinationMergesMissingModelsWithoutOverwrite() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/base/weights")
        try fixture.file("new/Whisper/large/weights", "large model")
        let prepared = try ModelStorageMigration.prepare(pairs: fixture.pairs())
        _ = prepared.removeOriginals()
        #expect(fixture.exists("new/Whisper/base/weights"))
        #expect(fixture.exists("new/Whisper/large/weights"))
    }

    @Test func conflictingModelIsRejectedBeforeAnyCopy() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/model", "old")
        try fixture.file("new/Whisper/model", "different")
        #expect(throws: ModelStorageMigration.MigrationError.self) {
            try ModelStorageMigration.prepare(pairs: fixture.pairs())
        }
        #expect(try String(contentsOf: fixture.url("old/Whisper/model"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: fixture.url("new/Whisper/model"), encoding: .utf8) == "different")
    }

    @Test func nestedDestinationCannotConsumeSource() throws {
        let fixture = try StorageFixture()
        try fixture.file("old/Whisper/model")
        #expect(throws: ModelStorageMigration.MigrationError.self) {
            try ModelStorageMigration.prepare(pairs: [.init(name: "Whisper", source: fixture.url("old"), destination: fixture.url("old/nested"))])
        }
        #expect(!fixture.exists("old/nested"))
    }

    @Test func missingCustomRootFailsWithoutRecreatingIt() throws {
        let fixture = try StorageFixture()
        #expect(throws: ModelStorage.RootError.self) { try ModelStorage.validateRoot(fixture.url("missing")) }
        #expect(!fixture.exists("missing"))
        #expect(throws: ModelStorage.RootError.self) { try ModelStorage.validateRoot(fixture.root, expectedVolumeUUID: "another-volume") }
        try ModelStorage.validateRoot(nil)
    }

    @Test func migrationExcludesActiveReadersAndBlocksNewLoads() throws {
        let activity = ModelStorageActivity()
        var reader: ModelStorageActivity.Lease? = try activity.acquire()
        #expect(throws: ModelStorageActivity.StorageError.self) { try activity.beginMigration() }
        withExtendedLifetime(reader) {}
        reader = nil
        let migration = try activity.beginMigration()
        #expect(activity.isMigrating)
        #expect(throws: ModelStorageActivity.StorageError.self) { try activity.acquire() }
        withExtendedLifetime(migration) {}
    }
}

struct LocalAudioConversionTests {
    private func floatFormat(rate: Double, channels: UInt32) -> AVAudioFormat? {
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels
        ) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                             sampleRate: rate,
                             interleaved: false,
                             channelLayout: layout)
    }

    @Test(arguments: [8_000.0, 16_000.0, 44_100.0, 48_000.0])
    func oneSecondOfAudioKeepsItsDuration(rate: Double) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let resampler = LocalAudioResampler()
        var output = [Float]()
        // Multiple buffers exercise fractional-rate converter state across tap calls.
        var offset = 0
        while offset < Int(rate) {
            let frames = min(1024, Int(rate) - offset)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            input.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { input.floatChannelData![0][i] = Float(sin(2 * Double.pi * 440 * Double(offset + i) / rate)) }
            output += try resampler.convert(input)
            offset += frames
        }
        #expect(abs(output.count - 16_000) < 64)
        // Ignore tiny filter ringing near zero rather than counting it as a cycle.
        var negative = false
        var crossings = 0
        for sample in output {
            if sample < -0.1 { negative = true }
            if negative && sample > 0.1 { crossings += 1; negative = false }
        }
        #expect(abs(crossings - 440) < 4)
    }

    @Test func multichannelNormalizationAvoidsPhaseCancellation() throws {
        let format = try #require(floatFormat(rate: 48_000, channels: 3))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        for frame in 0..<4_800 {
            let sample = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.6
            input.floatChannelData![0][frame] = sample
            input.floatChannelData![1][frame] = -sample
            input.floatChannelData![2][frame] = sample * 0.05
        }

        let output = try LocalAudioResampler(logLabel: "test").convert(input)
        let rms = sqrt(output.reduce(0) { $0 + $1 * $1 } / Float(output.count))
        #expect(output.count > 1_300)
        #expect(output.count < 1_700)
        #expect(rms > 0.35)
    }

    @Test func normalizerSelectsStrongestChannel() throws {
        let format = try #require(floatFormat(rate: 48_000, channels: 3))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        input.frameLength = 8
        for frame in 0..<8 {
            input.floatChannelData![0][frame] = 0.01
            input.floatChannelData![1][frame] = Float(frame + 1) * 0.1
            input.floatChannelData![2][frame] = -0.05
        }

        let output = try MicrophoneInputNormalizer(logLabel: "test").normalize(input)
        #expect(output.format.channelCount == 1)
        for frame in 0..<8 {
            #expect(abs(output.floatChannelData![0][frame] - Float(frame + 1) * 0.1) < 0.000_001)
        }
    }

    @Test func zeroFilledMultichannelRouteSurfacesAnIssue() throws {
        let format = try #require(floatFormat(rate: 48_000, channels: 3))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        input.frameLength = 24_000
        let normalizer = MicrophoneInputNormalizer(logLabel: "test")
        _ = try normalizer.normalize(input)
        #expect(normalizer.captureIssue?.contains("delivered only silence") == true)
    }
}

struct AICleanupFailureTests {
    @Test func missingKeyPreservesRawTextAndSurfacesFailure() async {
        let result = await AICleanupResult.process(text: "raw dictation", hasCredentials: false) {
            Issue.record("Cleanup must not be called without credentials")
            return "unexpected"
        }
        #expect(result.text == "raw dictation")
        #expect(result.failure != nil)
        #expect(!result.usedAI)
    }

    @Test func requestFailureAndSubsequentSuccessHaveIndependentStatus() async {
        let failed = await AICleanupResult.process(text: "raw", hasCredentials: true) {
            throw URLError(.timedOut)
        }
        let succeeded = await AICleanupResult.process(text: "raw", hasCredentials: true) { "Cleaned." }
        #expect(failed.text == "raw")
        #expect(failed.failure != nil)
        #expect(succeeded.text == "Cleaned.")
        #expect(succeeded.failure == nil)
        #expect(succeeded.usedAI)
    }
}

struct MicrophoneFormatTests {
    @Test func clientFormatUsesHardwareRateAndChannels() throws {
        var hardware = AudioStreamBasicDescription()
        hardware.mSampleRate = 48_000
        hardware.mChannelsPerFrame = 2
        let client = try #require(AudioSessionHelper.captureClientFormat(hardware: hardware))
        #expect(client.mSampleRate == 48_000)
        #expect(client.mChannelsPerFrame == 2)
        #expect(client.mFormatID == kAudioFormatLinearPCM)
        #expect(client.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        #expect(client.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        #expect(client.mBytesPerFrame == 4)
    }

    @Test func disconnectedDeviceCannotProduceAClientFormat() {
        #expect(AudioSessionHelper.captureClientFormat(hardware: AudioStreamBasicDescription()) == nil)
    }

    @Test func clientFormatSupportsFaceTimeThreeChannelRoute() throws {
        var hardware = AudioStreamBasicDescription()
        hardware.mSampleRate = 48_000
        hardware.mChannelsPerFrame = 3
        let client = try #require(AudioSessionHelper.captureClientFormat(hardware: hardware))
        #expect(client.mSampleRate == 48_000)
        #expect(client.mChannelsPerFrame == 3)
        #expect(client.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
    }
}

private actor LoadBarrier {
    private var release: CheckedContinuation<Void, Never>?
    private var entered = false
    private var entryWaiters = [CheckedContinuation<Void, Never>]()
    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func open() { release?.resume(); release = nil }
}

struct SharedModelLoadTests {
    @Test func concurrentCallerWaitsForPreload() async throws {
        let loader = SharedModelLoader<Int>()
        let barrier = LoadBarrier()
        let first = Task { try await loader.load(key: "base") { await barrier.wait(); return 42 } }
        await barrier.waitUntilEntered()
        let second = Task { try await loader.load(key: "base") { Issue.record("Loaded twice"); return -1 } }
        #expect(loader.isLoading)
        #expect(loader.value == nil)
        await barrier.open()
        #expect(try await first.value == 42)
        #expect(try await second.value == 42)
    }

    @Test func invalidatedFlightCannotReplaceNewModelWithSameKey() async throws {
        let loader = SharedModelLoader<Int>()
        let barrier = LoadBarrier()
        let old = Task { try await loader.load(key: "base") { await barrier.wait(); return 1 } }
        await barrier.waitUntilEntered()
        loader.invalidate()
        #expect(try await loader.load(key: "base") { 2 } == 2)
        await barrier.open()
        do { _ = try await old.value; Issue.record("Stale model published") }
        catch { #expect(error is CancellationError) }
        #expect(loader.value == 2)
    }
}

private final class WarmupEngine: STTEngineProtocol {
    let engineType = STTEngineType.whisper
    var isAvailable: Bool { true }
    let barrier = LoadBarrier()
    private let lock = NSLock()
    private var ready = false
    private var paused = false
    private var stopCount = 0
    var stops: Int { lock.withLock { stopCount } }
    var isPaused: Bool { lock.withLock { paused } }
    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        await barrier.wait()
        lock.withLock { ready = true }
    }
    func pauseCapture() { lock.withLock { paused = true } }
    func stopTranscription() async -> String? {
        lock.withLock { stopCount += 1; return ready ? "captured before release" : nil }
    }
}

@MainActor
struct DictationSessionRegressionTests {
    @Test func earlyStopPreservesWarmupTextAndFinalizesOnlyOnce() async throws {
        let engine = WarmupEngine()
        let session = DictationSession(engine: engine, profile: nil)
        let start = session.start(locale: .current) { _, _ in }
        await engine.barrier.waitUntilEntered()
        let manual = Task { await session.finish() }
        while !session.isFinishing { await Task.yield() }
        #expect(engine.isPaused)
        #expect(engine.stops == 0)
        let automatic = Task { await session.finish() }
        await engine.barrier.open()
        try await start.value
        #expect(await manual.value == "captured before release")
        #expect(await automatic.value == "captured before release")
        #expect(engine.stops == 1)
    }

    @Test func resolvedProfileRemainsASnapshot() {
        let original = Profile(name: "Private", inputLanguageCode: "en", outputLanguageCode: "en", tonePrompt: "Original", aiPostProcessing: false)
        var current = original
        let session = DictationSession(engine: WarmupEngine(), profile: current)
        current.aiPostProcessing = true
        current.tonePrompt = "Different app"
        #expect(session.profile?.aiPostProcessing == false)
        #expect(session.profile?.tonePrompt == "Original")
    }
}
