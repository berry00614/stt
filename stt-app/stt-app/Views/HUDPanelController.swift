import Cocoa
import SwiftUI
import Combine

/// Manages the dictation HUD panel — a small floating indicator shown during dictation.
@MainActor
final class HUDPanelController: ObservableObject {
    private var panel: NSPanel?

    /// Whether the HUD panel is currently visible.
    @Published private(set) var isOpen = false

    private var cancellables = Set<AnyCancellable>()

    /// Start observing a dictation service to show/hide the HUD automatically.
    func observe(dictationService: DictationService) {
        // Cancel previous observation
        cancellables.removeAll()

        dictationService.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .recording, .transcribing, .done(_), .error(_):
                    self?.show(dictationService: dictationService)
                case .idle:
                    // Brief delay before hiding to let the "done" state be visible
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        // Re-check state — if still idle, hide
                        if case .idle = dictationService.state {
                            self?.hide()
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func show(dictationService: DictationService) {
        // If already showing, update existing panel
        if let existingPanel = panel, existingPanel.isVisible {
            // Update content
            let hostingView = NSHostingView(
                rootView: DictationHUDView(dictationService: dictationService)
            )
            hostingView.autoresizingMask = [.width, .height]
            existingPanel.contentView = hostingView
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let windowFrame = panel.frame
            let originX = screenFrame.midX - windowFrame.width / 2
            let originY = screenFrame.midY - windowFrame.height / 2 + 100
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        let hostingView = NSHostingView(
            rootView: DictationHUDView(dictationService: dictationService)
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
    }

    func hide() {
        panel?.close()
        panel = nil
        isOpen = false
    }
}
