import Combine
import Foundation

/// Top-level coordinator for the live caption pipeline.
///
/// Assembles: AudioCaptureService → AudioRingBuffer → WhisperEngine → TranscriptOutput
///
/// Replaces `TranscriptionService` (which used whisper-server HTTP) with
/// the native in-process whisper.cpp C API pipeline.
@MainActor
final class LiveCaptionService: ObservableObject {

    // MARK: - Published State

    @Published var isRunning = false

    // MARK: - Components

    let audioCapture = AudioCaptureService()
    let ringBuffer = AudioRingBuffer(capacityInSamples: 480_000) // 30s at 16kHz
    let transcriptOutput = TranscriptOutput()

    private lazy var engine: WhisperEngine = {
        WhisperEngine(ringBuffer: ringBuffer)
    }()

    // MARK: - Callback Wiring

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        // 1. Request microphone permission
        guard await audioCapture.requestPermission() else {
            transcriptOutput.engineState = .error("Microphone permission denied")
            isRunning = false
            return
        }

        // 2. Resolve paths
        let settings = AppSettings.shared
        guard let modelPath = settings.resolvedModelPath(name: settings.streamModelName) else {
            transcriptOutput.engineState = .error("Model not found: \(settings.streamModelName)")
            isRunning = false
            return
        }

        let vadModelPath: String?
        if settings.vadMode == "silero" {
            vadModelPath = AppSettings.whisperVadModelPath()?.path
        } else {
            vadModelPath = nil
        }

        // 3. Load model
        do {
            try await engine.loadModel(
                modelPath: modelPath.path,
                vadModelPath: vadModelPath,
                language: settings.language
            )
        } catch {
            transcriptOutput.engineState = .error(error.localizedDescription)
            isRunning = false
            return
        }

        // 4. Wire engine → transcript output
        // WhisperEngine runs on its own actor, so we need to bridge to @MainActor
        await engine.setCallbacks(
            onTranscript: { [weak self] text in
                // Run filtering + normalization
                guard let self else { return }
                guard !AntiHallucination.isHallucination(text) else { return }
                let normalized = TextNormalizer.normalize(text, language: settings.language)
                Task { @MainActor in
                    self.transcriptOutput.append(text: normalized)
                }
            },
            onStateChange: { [weak self] state in
                Task { @MainActor in
                    self?.transcriptOutput.engineState = state
                }
            },
            onSpeakingChange: { [weak self] speaking in
                Task { @MainActor in
                    self?.transcriptOutput.isSpeaking = speaking
                }
            }
        )

        // 5. Wires audio → ring buffer
        audioCapture.onAudioChunkFloats = { [weak ringBuffer] floats in
            ringBuffer?.write(floats)
        }

        // 6. Start audio capture
        do {
            try audioCapture.start()
        } catch {
            transcriptOutput.engineState = .error("Audio capture failed: \(error.localizedDescription)")
            isRunning = false
            return
        }

        // 7. Start engine processing loop
        await engine.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        // Stop engine first (aborts current inference)
        Task {
            await engine.stop()
        }

        // Stop audio capture
        audioCapture.stop()

        // Clear transcript
        transcriptOutput.clear()
    }
}

// MARK: - WhisperEngine Callback Setup

extension WhisperEngine {
    /// Convenience method to set all callbacks at once.
    fileprivate func setCallbacks(
        onTranscript: @escaping (String) -> Void,
        onStateChange: @escaping (State) -> Void,
        onSpeakingChange: @escaping (Bool) -> Void
    ) {
        self.onTranscript = onTranscript
        self.onStateChange = onStateChange
        self.onSpeakingChange = onSpeakingChange
    }
}
