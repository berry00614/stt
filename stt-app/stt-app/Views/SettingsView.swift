import SwiftUI

/// Settings window accessible from the menu bar.
struct SettingsView: View {
    @AppStorage("model_name") private var modelName = "ggml-small.bin"
    @AppStorage("language") private var language = "auto"
    @AppStorage("dictation_hold_threshold") private var holdThreshold = 0.3
    @AppStorage("dictation_auto_paste") private var autoPaste = true
    @AppStorage("captions_stream_interval") private var streamInterval = 0.5
    @AppStorage("captions_silence_threshold") private var silenceThreshold = 0.01
    @AppStorage("captions_font_size") private var fontSize = 20.0
    @AppStorage("captions_max_lines") private var maxLines = 3.0
    @AppStorage("captions_window_opacity") private var windowOpacity = 0.85
    @AppStorage("auto_start_server") private var autoStartServer = false

    @State private var availableModels: [String] = []
    @State private var hasAccessibility: Bool = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            dictationTab
                .tabItem { Label("Dictation", systemImage: "mic.fill") }

            captionsTab
                .tabItem { Label("Captions", systemImage: "captions.bubble") }
        }
        .frame(width: 420, height: 380)
        .onAppear {
            availableModels = AppSettings.availableModels()
            hasAccessibility = PasteController.hasPastePermission
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                Picker("Model", selection: $modelName) {
                    if availableModels.isEmpty {
                        Text("No models found").tag(modelName)
                    }
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Picker("Language", selection: $language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("中文").tag("zh")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                .pickerStyle(.menu)

                Toggle("Auto-start server on launch", isOn: $autoStartServer)
                    .help("Keep whisper-server running for faster first dictation")
            } header: {
                Text("Model & Language")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dictation Tab

    private var dictationTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Hold threshold:")
                        Spacer()
                        Text(String(format: "%.1fs", holdThreshold))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $holdThreshold, in: 0.1...1.0, step: 0.1)
                    Text("How long to hold Right Option before recording starts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Auto-paste at cursor", isOn: $autoPaste)
                    .help("When off, text is only copied to clipboard")

                HStack {
                    Image(systemName: hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(hasAccessibility ? .green : .red)
                    Text(hasAccessibility ? "Accessibility permission granted" : "Accessibility permission required for paste")
                        .font(.caption)
                    if !hasAccessibility {
                        Button("Grant") {
                            PasteController.requestPastePermission()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                hasAccessibility = PasteController.hasPastePermission
                            }
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text("Push-to-Talk")
            }
            .onAppear {
                hasAccessibility = PasteController.hasPastePermission
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Captions Tab

    private var captionsTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Update interval:")
                        Spacer()
                        Text(String(format: "%.1fs", streamInterval))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $streamInterval, in: 0.3...2.0, step: 0.1)
                    Text("Lower = faster response, higher = less CPU")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Silence threshold:")
                        Spacer()
                        Text(String(format: "%.3f", silenceThreshold))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $silenceThreshold, in: 0.001...0.05, step: 0.001)
                    Text("Higher values require louder speech to trigger")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Font size:")
                        Spacer()
                        Text("\(Int(fontSize))pt")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $fontSize, in: 12...48, step: 2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max lines:")
                        Spacer()
                        Text("\(Int(maxLines))")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $maxLines, in: 1...10, step: 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Opacity:")
                        Spacer()
                        Text("\(Int(windowOpacity * 100))%")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $windowOpacity, in: 0.3...1.0, step: 0.05)
                }
            } header: {
                Text("Live Captions")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
