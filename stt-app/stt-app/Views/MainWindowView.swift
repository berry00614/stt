import SwiftUI

/// Main window content with three functional sections:
/// Dictation, Live Captions, and File Transcription.
struct MainWindowView: View {
    @ObservedObject var dictationService: DictationService
    @ObservedObject var transcriptionService: TranscriptionService
    @ObservedObject var captionWindowController: CaptionWindowController
    @ObservedObject var fileTranscriptionService: FileTranscriptionService

    var body: some View {
        VStack(spacing: 0) {
            // Custom title area
            titleBar

            Divider()
                .padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 14) {
                    dictationCard
                    captionsCard
                    fileCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }

            Divider()
                .padding(.horizontal, 16)

            // Bottom bar
            bottomBar
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440, idealHeight: 520)
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            Text("stt")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.primary)
            Text("— Local Speech-to-Text")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Spacer()

            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Settings…")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Text("Hold ⌥ (Right Option) to dictate from anywhere")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Dictation Card

    private var dictationCard: some View {
        CardView(
            icon: "mic.fill",
            iconColor: dictationIconColor,
            title: "Dictation",
            subtitle: dictationSubtitle,
            statusColor: dictationStatusColor,
            statusText: dictationStatusText
        ) {
            VStack(spacing: 10) {
                // Record button
                dictationButton

                // Duration display
                if case .recording = dictationService.state {
                    Text(String(format: "%.1f s", dictationService.recordingDuration))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                // Transcribing indicator
                if case .transcribing = dictationService.state {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Transcribing…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Model picker (only when idle)
            if case .idle = dictationService.state {
                modelPickerRow(
                    label: "Model:",
                    selection: Binding(
                        get: { AppSettings.shared.modelName },
                        set: { AppSettings.shared.modelName = $0 }
                    ),
                    disabled: false
                )
            }

            // Result text
            if case .done(let text) = dictationService.state {
                DictationResultView(text: text)
            }

            // Error
            if case .error(let msg) = dictationService.state {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
        }
    }

    private var dictationButton: some View {
        let isIdle = dictationService.state == .idle
        let isRecording = dictationService.state == .recording
        let isProcessing = dictationService.state == .transcribing

        return Button(action: {
            if isIdle {
                Task { await dictationService.startRecording() }
            } else if isRecording {
                Task { await dictationService.stopAndTranscribe() }
            }
        }) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.blue)
                    .frame(width: 48, height: 48)

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                        .colorInvert()
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isProcessing || dictationService.state.isTerminalState)
        .scaleEffect(isRecording ? 1.05 : 1.0)
        .animation(isRecording ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isRecording)
    }

    private var dictationIconColor: Color {
        switch dictationService.state {
        case .recording: return .red
        case .transcribing: return .orange
        case .done: return .green
        case .error: return .yellow
        case .idle: return .blue
        }
    }

    private var dictationSubtitle: String {
        switch dictationService.state {
        case .idle: return "Click to record, or hold Right Option"
        case .recording: return "Recording in progress…"
        case .transcribing: return "Processing audio…"
        case .done: return "Transcription complete"
        case .error: return "Transcription failed"
        }
    }

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
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .done: return "Done"
        case .error(let msg): return msg
        }
    }

    // MARK: - Live Captions Card

    private var captionsCard: some View {
        CardView(
            icon: "captions.bubble",
            iconColor: transcriptionService.isRunning ? .green : .gray,
            title: "Live Captions",
            subtitle: captionsSubtitle,
            statusColor: captionsStatusColor,
            statusText: captionsStatusText
        ) {
            // Model picker (only when stopped)
            if !transcriptionService.isRunning && !transcriptionService.serverManager.isLoading {
                modelPickerRow(
                    label: "Model:",
                    selection: Binding(
                        get: { AppSettings.shared.streamModelName },
                        set: { AppSettings.shared.streamModelName = $0 }
                    ),
                    disabled: false
                )
            }

            HStack(spacing: 8) {
                // Start/Stop button
                if transcriptionService.serverManager.isLoading {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Button("Cancel") {
                            transcriptionService.stop()
                        }
                    }
                } else if transcriptionService.isRunning {
                    Button(action: {
                        transcriptionService.stop()
                        captionWindowController.close()
                    }) {
                        Label("Stop Captions", systemImage: "stop.circle")
                    }
                } else {
                    Button(action: startCaptions) {
                        Label("Start Captions", systemImage: "captions.bubble")
                    }
                }

                // Caption window toggle
                if captionWindowController.isOpen {
                    Button(action: { captionWindowController.close() }) {
                        Label("Hide Window", systemImage: "eye.slash")
                    }
                } else {
                    Button(action: {
                        captionWindowController.open(transcriptionService: transcriptionService)
                    }) {
                        Label("Show Window", systemImage: "eye")
                    }
                    .disabled(!transcriptionService.isRunning)
                }
            }

            // Server error
            if let error = captionsErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            // Live text display
            if transcriptionService.isRunning {
                ScrollView {
                    Text(transcriptionService.displayText.isEmpty
                         ? "Listening…"
                         : transcriptionService.displayText)
                        .font(.system(size: 13))
                        .foregroundColor(transcriptionService.displayText.isEmpty
                                        ? .secondary : .primary)
                        .italic(transcriptionService.displayText.isEmpty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 40, maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
            }
        }
    }

    private var captionsSubtitle: String {
        if transcriptionService.serverManager.isLoading {
            return "Starting whisper-server…"
        } else if transcriptionService.isRunning {
            return "Streaming live transcription"
        } else {
            return "Continuous real-time captions from microphone"
        }
    }

    private var captionsStatusColor: Color {
        switch transcriptionService.serverManager.serverState {
        case .stopped: return .gray.opacity(0.4)
        case .starting: return .orange
        case .ready: return transcriptionService.isRunning ? .green : .blue
        case .error: return .red
        }
    }

    private var captionsStatusText: String {
        switch transcriptionService.serverManager.serverState {
        case .stopped: return "Off"
        case .starting: return "Starting…"
        case .ready: return transcriptionService.isRunning ? "Active" : "Ready"
        case .error: return "Error"
        }
    }

    private var captionsErrorMessage: String? {
        if case .error(let msg) = transcriptionService.serverManager.serverState {
            return msg.count > 100 ? String(msg.prefix(100)) + "…" : msg
        }
        return nil
    }

    // MARK: - Helpers

    /// A compact labeled model picker row.
    private func modelPickerRow(
        label: String,
        selection: Binding<String>,
        disabled: Bool
    ) -> some View {
        let models = AppSettings.availableModels()
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Picker("", selection: selection) {
                ForEach(models, id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11))
                        .tag(name)
                }
            }
            .labelsHidden()
            .disabled(disabled)
        }
    }

    private func startCaptions() {
        Task { @MainActor in
            await transcriptionService.start()
            if transcriptionService.isRunning {
                captionWindowController.open(transcriptionService: transcriptionService)
            }
        }
    }

    // MARK: - File Transcription Card

    private var fileCard: some View {
        CardView(
            icon: "doc.text",
            iconColor: fileIconColor,
            title: "Transcribe File",
            subtitle: fileSubtitle,
            statusColor: fileStatusColor,
            statusText: fileStatusText
        ) {
            HStack(spacing: 8) {
                Button(action: { fileTranscriptionService.selectFile() }) {
                    Label("Choose File…", systemImage: "folder")
                }

                if let url = fileTranscriptionService.selectedFileURL {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(action: { fileTranscriptionService.clearFile() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if fileTranscriptionService.selectedFileURL != nil {
                HStack(spacing: 8) {
                    Button(action: { fileTranscriptionService.transcribe() }) {
                        Label("Transcribe", systemImage: "play.circle")
                    }
                    .disabled(fileTranscriptionService.state == .transcribing)
                }
            }

            // Progress
            if case .transcribing = fileTranscriptionService.state {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Transcribing…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            // Result
            if case .done(let text) = fileTranscriptionService.state {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 40, maxHeight: 120)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )

                    HStack {
                        Button(action: { fileTranscriptionService.copyResult() }) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 12))
                        }

                        Spacer()

                        Button(action: { fileTranscriptionService.reset() }) {
                            Label("Clear", systemImage: "trash")
                                .font(.system(size: 12))
                        }
                    }
                }
            }

            // Error
            if case .error(let msg) = fileTranscriptionService.state {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
        }
    }

    private var fileIconColor: Color {
        switch fileTranscriptionService.state {
        case .transcribing: return .orange
        case .done: return .green
        case .error: return .red
        case .idle: return .purple
        }
    }

    private var fileSubtitle: String {
        switch fileTranscriptionService.state {
        case .idle: return "Choose an audio file to transcribe"
        case .transcribing: return "Processing file…"
        case .done: return "Transcription complete"
        case .error: return "Transcription failed"
        }
    }

    private var fileStatusColor: Color {
        switch fileTranscriptionService.state {
        case .idle: return .gray.opacity(0.4)
        case .transcribing: return .orange
        case .done: return .green
        case .error: return .red
        }
    }

    private var fileStatusText: String {
        switch fileTranscriptionService.state {
        case .idle: return "Ready"
        case .transcribing: return "Transcribing"
        case .done: return "Done"
        case .error: return "Error"
        }
    }
}

// MARK: - Subviews

/// A styled card container used for each functional section.
struct CardView<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let statusColor: Color
    let statusText: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Body
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

/// Displays dictation result with a Copy button and auto-clears.
struct DictationResultView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(text)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 30, maxHeight: 80)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )

            HStack {
                Button(action: { PasteController.copyToClipboard(text) }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }

                Spacer()

                Text("Auto-clears in 2s")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Extensions

extension DictationService.DictationState {
    /// Whether this state is a terminal display state
    /// (button should not trigger recording).
    var isTerminalState: Bool {
        switch self {
        case .idle, .recording: return false
        case .transcribing, .done, .error: return true
        }
    }
}
