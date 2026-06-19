import Combine
import Foundation

/// Thread-safe bridge between WhisperEngine (background actor) and SwiftUI (main actor).
///
/// Holds the rolling transcript display text and engine state for UI binding.
@MainActor
final class TranscriptOutput: ObservableObject {
    /// The current transcript text for display (last N segments joined).
    @Published var displayText: String = ""

    /// Whether speech is currently being detected/transcribed.
    @Published var isSpeaking: Bool = false

    /// Current engine lifecycle state.
    @Published var engineState: WhisperEngine.State = .idle

    /// Maximum number of text segments kept in the rolling window.
    var maxSegments: Int = 8

    /// Individual transcript segments (rolling window).
    private var segments: [String] = []

    /// Append a new transcript segment to the rolling window.
    func append(text: String) {
        guard !text.isEmpty else { return }

        // Check if this is an extension of the last segment (e.g. incremental result)
        // or a completely new segment. We use simple overlap detection:
        // if the new text starts with the last segment, it's an incremental update.
        if let last = segments.last, text.hasPrefix(last) {
            // Replace the last segment with the extended version
            segments[segments.count - 1] = text
        } else {
            // New segment
            segments.append(text)
            if segments.count > maxSegments {
                segments.removeFirst()
            }
        }

        displayText = segments.joined(separator: " ")
    }

    /// Clear all segments and reset display.
    func clear() {
        segments = []
        displayText = ""
        isSpeaking = false
    }
}
