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

    // MARK: - Native Engine (whisper.cpp C API)

    /// VAD mode: "silero" (neural), "energy" (RMS-based), or "none".
    @AppStorage("vad_mode")
    var vadMode: String = "silero"

    @AppStorage("engine_threads")
    var engineThreads: Int = 4

    // MARK: - Path Resolution

    /// Resolves the whisper.cpp project root for development builds.
    nonisolated static func whisperCppRoot() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["WHISPER_CPP_ROOT"] {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let candidates = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/coding/stt/whisper.cpp"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("projects/stt/whisper.cpp"),
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
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("bin/whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
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

    /// Returns model search directories in priority order.
    nonisolated static func modelDirectories() -> [URL] {
        var directories: [URL] = []

        if let configured = ProcessInfo.processInfo.environment["STT_MODELS_DIR"] {
            directories.append(URL(fileURLWithPath: configured))
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("models") {
            directories.append(bundled)
        }

        if let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            directories.append(
                applicationSupport
                    .appendingPathComponent("STT for Mac", isDirectory: true)
                    .appendingPathComponent("models", isDirectory: true)
            )
        }

        if let root = whisperCppRoot() {
            directories.append(root.appendingPathComponent("models"))
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Resolves the first existing models directory.
    nonisolated static func modelsDirectory() -> URL? {
        modelDirectories().first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Returns the path to the currently selected model.
    func resolvedModelPath(name: String? = nil) -> URL? {
        let filename = name ?? modelName
        return Self.modelDirectories()
            .map { $0.appendingPathComponent(filename) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Resolves the VAD model path.
    static func whisperVadModelPath() -> URL? {
        for modelsDir in modelDirectories() {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: modelsDir,
                includingPropertiesForKeys: nil
            ) else { continue }
            if let model = contents.first(where: {
                $0.lastPathComponent.hasPrefix("ggml-silero")
                    && $0.pathExtension == "bin"
            }) {
                return model
            }
        }
        return nil
    }

    /// Lists available model files in the models directory.
    static func availableModels() -> [String] {
        let models = modelDirectories().flatMap { modelsDir -> [String] in
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: modelsDir,
                includingPropertiesForKeys: nil
            ) else { return [] }
            return contents
                .filter {
                    $0.pathExtension == "bin"
                        && !$0.lastPathComponent.hasPrefix("ggml-silero")
                }
                .map(\.lastPathComponent)
        }
        return Array(Set(models)).sorted()
    }
}
