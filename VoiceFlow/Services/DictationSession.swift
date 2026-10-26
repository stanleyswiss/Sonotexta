import Foundation

/// A single session owns its engine, profile and asynchronous finalization.
/// All entry points run on the main actor; engine internals may do background work.
@MainActor
final class DictationSession {
    let id = UUID()
    let engine: STTEngineProtocol
    let profile: Profile?
    private var startTask: Task<Void, Error>?
    private var finishTask: Task<String?, Never>?
    private(set) var isFinishing = false
    private(set) var startError: Error?

    init(engine: STTEngineProtocol, profile: Profile?) {
        self.engine = engine
        self.profile = profile
    }

    func start(locale: Locale, onResult: @escaping (String, Bool) -> Void) -> Task<Void, Error> {
        if let startTask { return startTask }
        let task = Task {
            guard !isFinishing else { throw CancellationError() }
            do { try await engine.startTranscription(locale: locale, onResult: onResult) }
            catch {
                startError = error
                throw error
            }
        }
        startTask = task
        return task
    }

    func finish() async -> String? {
        if let finishTask { return await finishTask.value }
        isFinishing = true
        // Freeze the captured audio at key release, but keep the buffered samples
        // until the in-flight model load is ready to transcribe them.
        engine.pauseCapture()
        let task = Task { [self] in
            _ = try? await startTask?.value
            engine.pauseCapture()
            return await engine.stopTranscription()
        }
        finishTask = task
        return await task.value
    }
}
