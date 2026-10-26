import Foundation
import FluidAudio

/// Chunk-size selector for the Parakeet Realtime EOU 120M streaming engine.
/// Maps 1:1 to FluidAudio's `StreamingChunkSize` for the variants we ship.
enum ParakeetRealtimeChunkSize: String, CaseIterable, Identifiable, Codable {
    case ms160 = "160ms"
    case ms320 = "320ms"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ms160: return "160ms (fastest, ~8-9% WER)"
        case .ms320: return "320ms (better accuracy, lower throughput)"
        }
    }

    var qualityDescription: String {
        switch self {
        case .ms160: return "Lowest latency — 160ms between partials. Recommended for live dictation."
        case .ms320: return "Slightly higher accuracy at 320ms latency. Use if 160ms feels jumpy."
        }
    }

    /// Subfolder under `~/Library/Application Support/FluidAudio/Models/parakeet-eou-streaming/`
    /// where the variant's `.mlmodelc` bundles live after download.
    var folderName: String { rawValue }

    /// Map to FluidAudio's library-level chunk size.
    var libraryChunkSize: StreamingChunkSize {
        switch self {
        case .ms160: return .ms160
        case .ms320: return .ms320
        }
    }
}
