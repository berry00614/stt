import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Handles transcription of user-selected audio files via whisper-cli.
/// Converts any supported audio format to 16kHz mono WAV before transcription,
/// ensuring consistent input regardless of source format.
@MainActor
final class FileTranscriptionService: ObservableObject {

    enum State: Equatable {
        case idle
        case transcribing
        case done(String)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var selectedFileURL: URL?

    // MARK: - File Selection

    /// Present an NSOpenPanel for selecting an audio file.
    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .wav,
            .mp3,
            .mpeg4Audio,
            .aiff,
            UTType(filenameExtension: "flac"),
            UTType(filenameExtension: "ogg"),
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Select Audio File to Transcribe"
        panel.message = "Choose an audio file (WAV, MP3, M4A, FLAC, AIFF, OGG)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFileURL = url
        state = .idle
    }

    /// Clear the selected file.
    func clearFile() {
        selectedFileURL = nil
        state = .idle
    }

    // MARK: - Transcription

    /// Transcribe the selected file using whisper-cli.
    /// Converts to 16kHz mono WAV first, then runs whisper-cli off the main actor.
    func transcribe() {
        guard let fileURL = selectedFileURL else {
            state = .error("No file selected")
            return
        }
        guard case .idle = state else { return }

        state = .transcribing

        let modelName = AppSettings.shared.modelName
        let language = AppSettings.shared.language

        Task.detached(priority: .userInitiated) {
            do {
                // 1. Convert to 16kHz mono PCM, then build WAV (nonisolated)
                let wavData = try await Self.convertAudioFile(fileURL: fileURL)

                // 2. Run whisper-cli (blocking call, off main actor, nonisolated)
                let rawText = try Self.runWhisperCLI(
                    wavData: wavData,
                    modelName: modelName,
                    language: language
                )

                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

                // Normalize + update state on main actor
                await MainActor.run {
                    let normalized = TextNormalizer.normalize(trimmed, language: language)
                    if normalized.isEmpty {
                        self.state = .done("(no speech detected)")
                    } else {
                        self.state = .done(normalized)
                    }
                }
            } catch {
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Actions

    /// Copy the transcription result to the clipboard.
    func copyResult() {
        if case .done(let text) = state {
            PasteController.copyToClipboard(text)
        }
    }

    /// Reset to idle, clearing file and result.
    func reset() {
        selectedFileURL = nil
        state = .idle
    }

    // MARK: - Audio Conversion (non-isolated)

    /// Converts an audio file (any format) to a 16kHz mono 16-bit PCM WAV Data.
    /// Uses AVAssetReader to decode, then AntiHallucination.buildWAV to encode.
    private nonisolated static func convertAudioFile(fileURL: URL) async throws -> Data {
        let asset = AVURLAsset(url: fileURL)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw FileTranscriptionError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw FileTranscriptionError.conversionFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            throw FileTranscriptionError.conversionFailed(
                reader.error?.localizedDescription ?? "Failed to start reading audio"
            )
        }

        var pcmData = Data()

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var buffer = Data(count: length)
            let status = buffer.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            if status == kCMBlockBufferNoErr {
                pcmData.append(buffer)
            }
        }

        guard reader.status == .completed else {
            throw FileTranscriptionError.conversionFailed(
                reader.error?.localizedDescription ?? "Audio reading did not complete"
            )
        }

        guard !pcmData.isEmpty else {
            throw FileTranscriptionError.conversionFailed("Decoded audio is empty")
        }

        // Build WAV container around raw PCM (same approach as DictationService)
        return AntiHallucination.buildWAV(pcmData: pcmData)
    }

    // MARK: - whisper-cli Execution (non-isolated)

    /// Runs whisper-cli on WAV data. Blocking call — must run off the main actor.
    private nonisolated static func runWhisperCLI(
        wavData: Data,
        modelName: String,
        language: String
    ) throws -> String {
        guard let cliPath = AppSettings.whisperCliPath() else {
            throw FileTranscriptionError.whisperCliNotFound
        }
        guard let modelsDir = AppSettings.modelsDirectory() else {
            throw FileTranscriptionError.modelNotFound(modelName)
        }
        let modelPath = modelsDir.appendingPathComponent(modelName)
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw FileTranscriptionError.modelNotFound(modelName)
        }

        // Write WAV to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempWAV = tempDir.appendingPathComponent("stt_file_\(UUID().uuidString).wav")
        try wavData.write(to: tempWAV)
        defer { try? FileManager.default.removeItem(at: tempWAV) }

        let process = Process()
        process.executableURL = cliPath
        process.arguments = [
            "-m", modelPath.path,
            "-f", tempWAV.path,
            "-l", language,
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
            throw FileTranscriptionError.whisperCliFailed(errorStr)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Filter known false outputs (same as DictationService)
        if text == "[BLANK_AUDIO]" || text == "[ Silence ]" {
            return ""
        }

        return text
    }
}

// MARK: - Errors

enum FileTranscriptionError: LocalizedError {
    case whisperCliNotFound
    case modelNotFound(String)
    case whisperCliFailed(String)
    case noAudioTrack
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .whisperCliNotFound:
            return "whisper-cli not found. Make sure whisper.cpp is built."
        case .modelNotFound(let name):
            return "Model not found: \(name)"
        case .whisperCliFailed(let details):
            return "whisper-cli failed: \(details)"
        case .noAudioTrack:
            return "No audio track found in the selected file."
        case .conversionFailed(let details):
            return "Audio conversion failed: \(details)"
        }
    }
}
