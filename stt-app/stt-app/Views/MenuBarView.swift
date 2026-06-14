import SwiftUI

/// Content for the MenuBarExtra menu.
struct MenuBarView: View {
    @ObservedObject var dictationService: DictationService
    @ObservedObject var transcriptionService: TranscriptionService
    let captionWindowController: CaptionWindowController

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading) {
            statusSection

            Divider()

            actionsSection

            Divider()

            footerSection
        }
        .padding(.vertical, 4)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Dictation status
            HStack(spacing: 8) {
                Circle()
                    .fill(dictationStatusColor)
                    .frame(width: 8, height: 8)
                Text("Dictation: \(dictationStatusText)")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)

            // Server/captions status
            HStack(spacing: 8) {
                Circle()
                    .fill(captionStatusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Captions: \(captionStatusText)")
                        .font(.system(size: 12))
                    if let error = serverErrorMessage {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 12)

            // Hotkey reminder
            Text(hotkeyHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Group {
            // --- Captions server control ---
            if transcriptionService.serverManager.isLoading {
                // Starting: show cancel
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Starting server...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                Button(action: stopCaptions) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else if transcriptionService.isRunning {
                // Running: show stop
                Button(action: stopCaptions) {
                    Label("Stop Captions", systemImage: "stop.circle")
                }
                // Window toggle
                if captionWindowController.isOpen {
                    Button(action: { captionWindowController.close() }) {
                        Label("Hide Caption Window", systemImage: "eye.slash")
                    }
                } else {
                    Button(action: {
                        captionWindowController.open(transcriptionService: transcriptionService)
                    }) {
                        Label("Show Caption Window", systemImage: "eye")
                    }
                }
            } else {
                // Stopped: show start
                Button(action: startCaptions) {
                    Label("Start Captions", systemImage: "captions.bubble")
                }
            }

            Button(action: { openWindow(id: "main") }) {
                Label("Show Main Window", systemImage: "macwindow")
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            SettingsLink {
                Label("Settings...", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private var footerSection: some View {
        Group {
            Button(action: quit) {
                Label("Quit STT for Mac", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    // MARK: - Derived values

    private var dictationStatusColor: Color {
        switch dictationService.state {
        case .idle: return .gray.opacity(0.4)
        case .recording: return .red
        case .transcribing: return .orange
        case .done: return .green
        case .error: return .yellow
        }
    }

    private var dictationStatusText: String {
        switch dictationService.state {
        case .idle: return "Idle"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .done: return "Done"
        case .error(let msg): return msg
        }
    }

    private var captionStatusColor: Color {
        switch transcriptionService.serverManager.serverState {
        case .stopped: return .gray.opacity(0.4)
        case .starting: return .orange
        case .ready: return transcriptionService.isRunning ? .green : .blue
        case .error: return .red
        }
    }

    private var captionStatusText: String {
        switch transcriptionService.serverManager.serverState {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .ready: return transcriptionService.isRunning ? "Active" : "Ready"
        case .error: return "Error"
        }
    }

    private var hotkeyHint: String {
        AppSettings.shared.dictationMode == "click"
            ? "Press ⌥ (Right Option) to toggle dictation"
            : "Hold ⌥ (Right Option) to dictate"
    }

    private var serverErrorMessage: String? {
        if case .error(let msg) = transcriptionService.serverManager.serverState {
            // Truncate long messages
            if msg.count > 80 {
                return String(msg.prefix(80)) + "..."
            }
            return msg
        }
        return nil
    }

    // MARK: - Actions

    private func startCaptions() {
        Task { @MainActor in
            await transcriptionService.start()
            if transcriptionService.isRunning {
                captionWindowController.open(transcriptionService: transcriptionService)
            }
        }
    }

    private func stopCaptions() {
        transcriptionService.stop()
        captionWindowController.close()
    }

    private func quit() {
        transcriptionService.stop()
        captionWindowController.close()
        NSApplication.shared.terminate(nil)
    }
}
