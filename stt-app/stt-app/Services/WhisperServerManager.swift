import Combine
import Foundation

/// Manages the whisper-server process lifecycle.
/// Handles: find free port → spawn server → health polling → graceful shutdown.
@MainActor
final class WhisperServerManager: ObservableObject {

    // MARK: - State

    enum ServerState: Equatable {
        case stopped
        case starting
        case ready(port: Int)
        case error(String)
    }

    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var lastError: String?

    private var serverProcess: Process?
    private var stderrBuffer = ""

    /// The port the server is running on (valid when state == .ready).
    var port: Int? {
        if case .ready(let p) = serverState { return p }
        return nil
    }

    /// Whether the server is ready to accept inference requests.
    var isReady: Bool {
        if case .ready = serverState { return true }
        return false
    }

    /// Whether we're waiting for the server to come up.
    var isLoading: Bool {
        if case .starting = serverState { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Start whisper-server. No-op if already running.
    /// - Parameter modelOverride: if non-nil, use this model name instead of AppSettings.shared.modelName
    func start(modelOverride: String? = nil) async {
        guard case .stopped = serverState else { return }
        stderrBuffer = ""

        guard let serverPath = AppSettings.whisperServerPath() else {
            let msg = "whisper-server binary not found. Expected at: whisper.cpp/build/bin/whisper-server"
            print("[WhisperServer] \(msg)")
            serverState = .error(msg)
            lastError = msg
            return
        }
        let modelName = modelOverride ?? AppSettings.shared.modelName
        guard let modelPath = AppSettings.shared.resolvedModelPath(name: modelName) else {
            let msg = "Model not found: \(modelName)"
            print("[WhisperServer] \(msg)")
            serverState = .error(msg)
            lastError = msg
            return
        }

        print("[WhisperServer] Binary: \(serverPath.path)")
        print("[WhisperServer] Model:  \(modelPath.path)")

        let port = findFreePort()
        print("[WhisperServer] Starting on port \(port)...")
        serverState = .starting

        let process = Process()
        process.executableURL = serverPath
        process.arguments = [
            "-m", modelPath.path,
            "-l", AppSettings.shared.language,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--no-timestamps",
            "-t", "6",
            "-nth", "0.5",
        ]

        // Capture stderr for diagnostics
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        // Accumulate stderr asynchronously
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.stderrBuffer += str
                }
            }
        }

        do {
            try process.run()
            serverProcess = process

            // Poll health endpoint until ready
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                // Check if process died
                if !process.isRunning {
                    let exitCode = process.terminationStatus
                    let errorDetail = stderrBuffer
                        .split(separator: "\n")
                        .suffix(3)
                        .joined(separator: "\n")
                    let msg = "whisper-server exited with code \(exitCode): \(errorDetail)"
                    print("[WhisperServer] \(msg)")
                    serverState = .error(msg)
                    lastError = msg
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    serverProcess = nil
                    return
                }

                if await checkHealth(port: port) {
                    print("[WhisperServer] Ready on port \(port)")
                    serverState = .ready(port: port)
                    lastError = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            }

            // Timed out
            process.terminate()
            let errorDetail = stderrBuffer
                .split(separator: "\n")
                .suffix(3)
                .joined(separator: "\n")
            let msg = "whisper-server failed to start within 15s: \(errorDetail)"
            print("[WhisperServer] \(msg)")
            serverState = .error(msg)
            lastError = msg
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            serverProcess = nil
        } catch {
            let msg = "Failed to launch whisper-server: \(error.localizedDescription)"
            print("[WhisperServer] \(msg)")
            serverState = .error(msg)
            lastError = msg
        }
    }

    /// Stop the running whisper-server.
    func stop() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
        serverState = .stopped
    }

    /// Send a WAV chunk to the inference endpoint.
    /// Returns transcribed text, or empty string on failure.
    func transcribe(wavData: Data, filename: String) async -> String {
        guard let port = port else { return "" }

        let url = URL(string: "http://127.0.0.1:\(port)/inference")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = "----WhisperBoundary"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return ""
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                return ""
            }

            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    // MARK: - Helpers

    private func findFreePort() -> Int {
        let socket = Darwin.socket(AF_INET, Darwin.SOCK_STREAM, 0)
        guard socket >= 0 else { return 8080 }
        defer { Darwin.close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else { return 8080 }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsockResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socket, $0, &len)
            }
        }

        guard getsockResult >= 0 else { return 8080 }
        return Int(CFSwapInt16BigToHost(addr.sin_port))
    }

    private func checkHealth(port: Int) async -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "ok" else {
                return false
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Data append helpers

private extension Data {
    mutating func append(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        self.append(data)
    }
}
