import SwiftUI
import Combine

/// NSApplicationDelegate for menu bar app lifecycle and permission setup.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let dictationService = DictationService()
    let transcriptionService = TranscriptionService()
    let captionWindowController = CaptionWindowController()
    let hudController = HUDPanelController()
    let fileTranscriptionService = FileTranscriptionService()

    /// Tracks whether the Settings window is currently open.
    @Published var isSettingsOpen = false
    /// Tracks whether the main window is currently open.
    @Published var isMainWindowOpen = false

    private var cancellables = Set<AnyCancellable>()

    /// Closure that opens the main SwiftUI window — set by STTForMacApp.body.
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start HUD observation
        hudController.observe(dictationService: dictationService)

        // Start hotkey monitoring
        startHotkeyMonitor()

        // Observe window state to toggle Dock visibility
        observeWindows()

        // Show main window automatically on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.openMainWindow?()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriptionService.stop()
        captionWindowController.close()
        hudController.hide()
    }

    // MARK: - Dock Visibility

    /// Observe all window-open states and toggle the Dock icon accordingly:
    ///   - `.accessory` when only the menu bar is visible (no Dock icon)
    ///   - `.regular`   when any window is open (shows in Dock)
    private func observeWindows() {
        Publishers.MergeMany(
            captionWindowController.$isOpen,
            hudController.$isOpen,
            $isSettingsOpen,
            $isMainWindowOpen
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateActivationPolicy()
        }
        .store(in: &cancellables)

        // Set initial state (no windows open → .accessory)
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        let hadVisibleWindow = NSApp.activationPolicy() == .regular

        // HUD is intentionally excluded — it's a non-activating overlay that must
        // never steal focus from the app the user is dictating into.
        let hasVisibleWindow = captionWindowController.isOpen
                            || isSettingsOpen
                            || isMainWindowOpen

        if hasVisibleWindow {
            NSApp.setActivationPolicy(.regular)
            // Bring the app forward so the user sees the window they just opened
            if !hadVisibleWindow {
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Hotkey Setup

    private func startHotkeyMonitor() {
        let success = dictationService.startMonitoring()

        if !success {
            // Carbon RegisterEventHotKey requires Accessibility permission.
            // The same permission is used for paste (CGEventPost).
            // On first failure, request Accessibility and retry.
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
            let trusted = AXIsProcessTrustedWithOptions(options)

            if !trusted {
                // Show help alert
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let alert = NSAlert()
                    alert.messageText = "Accessibility Access Required"
                    alert.informativeText = """
                        STT for Mac needs Accessibility access to detect the Right Option key and paste text.

                        Go to System Settings > Privacy & Security > Accessibility,
                        then enable STT for Mac. You may need to relaunch the app.

                        (No other permissions are needed — no Input Monitoring, no special entitlements.)
                        """
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                }
            }
        } else {
            print("[AppDelegate] Hotkey monitor started successfully")
        }
    }
}

// MARK: - App

@main
struct STTForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu bar extra (always visible)
        MenuBarExtra {
            MenuBarView(
                dictationService: appDelegate.dictationService,
                transcriptionService: appDelegate.transcriptionService,
                captionWindowController: appDelegate.captionWindowController
            )
        } label: {
            let isActive = appDelegate.dictationService.state == .recording ||
                           appDelegate.dictationService.state == .transcribing ||
                           appDelegate.transcriptionService.isRunning

            Image(systemName: isActive ? "mic.fill" : "mic")
                .symbolRenderingMode(isActive ? .hierarchical : .monochrome)
                .foregroundStyle(isActive ? .red : .primary)
                // Bridge openWindow to AppDelegate at launch so the main
                // window can be auto-opened in applicationDidFinishLaunching.
                .task {
                    appDelegate.openMainWindow = { openWindow(id: "main") }
                }
        }
        .menuBarExtraStyle(.menu)

        // Main window — the primary interface
        Window("STT for Mac", id: "main") {
            MainWindowView(
                dictationService: appDelegate.dictationService,
                transcriptionService: appDelegate.transcriptionService,
                captionWindowController: appDelegate.captionWindowController,
                fileTranscriptionService: appDelegate.fileTranscriptionService
            )
            .onAppear { appDelegate.isMainWindowOpen = true }
            .onDisappear { appDelegate.isMainWindowOpen = false }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 520)

        // Settings scene — automatically adds Settings… (⌘,) to the app menu
        Settings {
            SettingsView()
                .onAppear { appDelegate.isSettingsOpen = true }
                .onDisappear { appDelegate.isSettingsOpen = false }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 380)
    }
}
