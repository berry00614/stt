import Foundation
import Combine
import AudioToolbox

/// Orchestrates the push-to-talk dictation workflow:
///   Hotkey hold → record → whisper-cli → normalize → paste result
@MainActor
final class DictationService: ObservableObject {

    // MARK: - State

    enum DictationState: Equatable {
        case idle
        case recording
        case transcribing
        case done(String)    // success with result text
        case error(String)   // error message
    }

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0

    // MARK: - Dependencies

    private let audioCapture = AudioCaptureService()
    private let hotkeyMonitor = HotkeyMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?

    // MARK: - Lifecycle

    init() {
        setupBindings()
    }

    private func setupBindings() {
        hotkeyMonitor.onTriggerRecording
            .sink { [weak self] in
                Task { await self?.startRecording() }
            }
            .store(in: &cancellables)

        hotkeyMonitor.onStopRecording
            .sink { [weak self] in
                Task { await self?.stopAndTranscribe() }
            }
            .store(in: &cancellables)

        hotkeyMonitor.onCancel
            .sink { [weak self] in
                self?.cancelRecording()
            }
            .store(in: &cancellables)
    }

    /// Start the hotkey monitor. Call once at app launch.
    func startMonitoring() -> Bool {
        return hotkeyMonitor.start()
    }

    // MARK: - Recording

    func startRecording() async {
        guard state == .idle else { return }

        let hasPermission = await audioCapture.requestPermission()
        guard hasPermission else {
            state = .error("Microphone permission denied. Grant it in System Settings > Privacy & Security > Microphone.")
            return
        }

        do {
            audioCapture.resetBuffer()
            try audioCapture.start()
            state = .recording
            recordingDuration = 0

            // Audio feedback
            AudioServicesPlaySystemSound(1113)  // System "begin record" chime

            // Update duration display
            durationTimer = Timer.scheduledTimer(
                withTimeInterval: 0.1,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recordingDuration += 0.1
                }
            }
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopAndTranscribe() async {
        guard case .recording = state else { return }

        durationTimer?.invalidate()
        durationTimer = nil
        audioCapture.stop()

        let audioData = audioCapture.accumulatedData
        audioCapture.resetBuffer()

        // Minimum recording length check
        let minDuration: TimeInterval = 0.3
        guard recordingDuration >= minDuration, audioData.count > 1600 else {
            state = .idle
            return
        }

        state = .transcribing

        do {
            let text = try await transcribe(pcmData: audioData)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state = .idle
                return
            }

            // Normalize (rule-based error correction)
            let normalized = TextNormalizer.normalize(trimmed, language: AppSettings.shared.language)

            // Audio feedback
            AudioServicesPlaySystemSound(1114)  // System "complete" chime

            if AppSettings.shared.dictationAutoPaste {
                await PasteController.pasteAtCursor(normalized)
            } else {
                PasteController.copyToClipboard(normalized)
            }

            state = .done(normalized)

            // Auto-reset to idle after showing result
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                if case .done = self?.state {
                    self?.state = .idle
                }
            }
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    func cancelRecording() {
        durationTimer?.invalidate()
        durationTimer = nil
        audioCapture.stop()
        audioCapture.resetBuffer()
        state = .idle
    }

    // MARK: - Transcription (whisper-cli)

    private func transcribe(pcmData: Data) async throws -> String {
        guard let cliPath = AppSettings.whisperCliPath() else {
            throw DictationError.whisperCliNotFound
        }
        guard let modelPath = AppSettings.shared.resolvedModelPath() else {
            throw DictationError.modelNotFound(AppSettings.shared.modelName)
        }

        // Write WAV to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempWav = tempDir.appendingPathComponent("stt_dictation_\(UUID().uuidString).wav")

        let wavData = AntiHallucination.buildWAV(pcmData: pcmData)
        try wavData.write(to: tempWav)

        defer {
            try? FileManager.default.removeItem(at: tempWav)
        }

        // Run whisper-cli
        let process = Process()
        process.executableURL = cliPath
        process.arguments = [
            "-m", modelPath.path,
            "-f", tempWav.path,
            "-l", AppSettings.shared.language,
            "--no-timestamps",
            "-otxt",
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw DictationError.whisperCliFailed(errorStr)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Filter common false outputs
        if text == "[BLANK_AUDIO]" || text == "[ Silence ]" {
            return ""
        }

        return text
    }
}

// MARK: - Errors

enum DictationError: LocalizedError {
    case whisperCliNotFound
    case modelNotFound(String)
    case whisperCliFailed(String)

    var errorDescription: String? {
        switch self {
        case .whisperCliNotFound:
            return "whisper-cli not found. Make sure whisper.cpp is built."
        case .modelNotFound(let name):
            return "Model not found: \(name)"
        case .whisperCliFailed(let details):
            return "whisper-cli failed: \(details)"
        }
    }
}
