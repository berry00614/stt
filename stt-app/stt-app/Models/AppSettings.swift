import Foundation
import SwiftUI

/// Centralized app settings backed by UserDefaults.
/// Access via `@AppStorage` in views or directly via `AppSettings.shared`.
final class AppSettings {
    static let shared = AppSettings()

    // MARK: - Model & Language

    @AppStorage("model_name")
    var modelName: String = "ggml-small.bin"

    @AppStorage("stream_model_name")
    var streamModelName: String = "ggml-tiny.en.bin"

    @AppStorage("language")
    var language: String = "auto"

    // MARK: - Dictation

    /// "hold" = hold Right Option to dictate; "click" = press once to start, press again to stop.
    @AppStorage("dictation_mode")
    var dictationMode: String = "hold"

    @AppStorage("dictation_hold_threshold")
    var dictationHoldThreshold: Double = 0.1

    @AppStorage("dictation_auto_paste")
    var dictationAutoPaste: Bool = true

    // MARK: - Live Captions

    @AppStorage("captions_stream_interval")
    var captionsStreamInterval: Double = 0.5

    @AppStorage("captions_window_seconds")
    var captionsWindowSeconds: Double = 3.0

    @AppStorage("captions_silence_threshold")
    var captionsSilenceThreshold: Double = 0.01

    @AppStorage("captions_font_size")
    var captionsFontSize: Double = 20.0

    @AppStorage("captions_max_lines")
    var captionsMaxLines: Int = 3

    @AppStorage("captions_window_opacity")
    var captionsWindowOpacity: Double = 0.85

    // MARK: - Server

    @AppStorage("auto_start_server")
    var autoStartServer: Bool = false

    // MARK: - Path Resolution

    /// Resolves the whisper.cpp project root.
    /// Looks relative to the app bundle for development builds,
    /// or at common installation paths.
    nonisolated static func whisperCppRoot() -> URL? {
        // 1. Check environment variable (for development)
        if let envPath = ProcessInfo.processInfo.environment["WHISPER_CPP_ROOT"] {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // 2. Look relative to the running app (development in Xcode)
        // The app runs from DerivedData; the project is at ~/Documents/coding/stt
        let candidates = [
            // Development: relative to source repo
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/coding/stt/whisper.cpp"),
            // Home directory projects
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("projects/stt/whisper.cpp"),
            // Direct home
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("stt/whisper.cpp"),
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    /// Resolves the whisper-cli binary path.
    nonisolated static func whisperCliPath() -> URL? {
        guard let root = whisperCppRoot() else { return nil }
        let path = root.appendingPathComponent("build/bin/whisper-cli")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Resolves the whisper-server binary path.
    nonisolated static func whisperServerPath() -> URL? {
        guard let root = whisperCppRoot() else { return nil }
        let path = root.appendingPathComponent("build/bin/whisper-server")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Resolves the models directory.
    nonisolated static func modelsDirectory() -> URL? {
        guard let root = whisperCppRoot() else { return nil }
        let path = root.appendingPathComponent("models")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Returns the path to the currently selected model.
    func resolvedModelPath(name: String? = nil) -> URL? {
        guard let modelsDir = Self.modelsDirectory() else { return nil }
        let path = modelsDir.appendingPathComponent(name ?? modelName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Lists available model files in the models directory.
    static func availableModels() -> [String] {
        guard let modelsDir = modelsDirectory() else { return [] }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.pathExtension == "bin" }
            .map { $0.lastPathComponent }
            .sorted()
    }
}
