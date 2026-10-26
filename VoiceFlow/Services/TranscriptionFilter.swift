import Foundation

/// Silently removes non-speech artifacts (music tags, silence markers, sound
/// effects) that STT engines sometimes emit.  Applied automatically before
/// AI post-processing or text delivery — the user never sees these tokens.
struct TranscriptionFilter {

    // MARK: - Ignored patterns

    /// Bracket / parenthesis tokens produced by Whisper, Parakeet, Deepgram, etc.
    /// Order doesn't matter — every pattern is checked via case-insensitive replace.
    private static let ignoredPatterns: [String] = [
        // Silence / blank
        "[BLANK_AUDIO]",
        "[ BLANK_AUDIO ]",
        "[blank_audio]",
        "[silence]",
        "[ Silence ]",
        "( silence )",
        "(silence)",
        "[no audio]",
        "[Silencio]",

        // Music
        "[Music]",
        "[music]",
        "[MUSIC]",
        "[MUSIC PLAYING]",
        "(music)",

        // Pauses
        "[ Pause ]",
        "[Pause]",
        "(Pause)",

        // Sounds / actions
        "[GASP]",
        "(crunching)",
        "(door slams)",
        "(scissors snipping)",
        "(Applause.)",
        "(Applause)",
        "( retirement bell rang )",

        // Inaudible
        "[inaudible]",
        "(inaudible)",
    ]

    // MARK: - Public API

    /// Remove artifact segments from transcription text.
    /// Returns the cleaned string, or empty if nothing meaningful remains.
    static func clean(_ text: String) -> String {
        var result = text

        for pattern in ignoredPatterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }

        // Also strip any remaining bracketed/parenthesised non-speech markers
        // that we didn't explicitly list, e.g. "[Laughter]", "(sighs)"
        // Pattern: text inside [] or () that is ≤40 chars and contains no digits
        result = result.replacingOccurrences(
            of: "\\[\\s*[A-Za-z_ ]{1,40}\\s*\\]",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\(\\s*[A-Za-z_ ]{1,40}\\s*\\)",
            with: "",
            options: .regularExpression
        )

        // Collapse runs of whitespace left by removals
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
