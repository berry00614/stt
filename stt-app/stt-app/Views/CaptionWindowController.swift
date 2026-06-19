import Cocoa
import SwiftUI
import Combine

/// NSPanel subclass that creates a floating overlay window for live captions.
/// Stays above all windows including fullscreen apps.
final class CaptionWindowController: NSObject, ObservableObject {

    private var panel: NSPanel?

    @Published private(set) var isOpen = false

    /// Toggle the caption overlay visibility.
    func toggle(transcriptOutput: TranscriptOutput) {
        if isOpen {
            close()
        } else {
            open(transcriptOutput: transcriptOutput)
        }
    }

    /// Open the caption overlay.
    func open(transcriptOutput: TranscriptOutput) {
        guard !isOpen else { return }

        let panel = CaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .resizable],
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
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        // Position at bottom center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = panel.frame
            let originX = screenFrame.midX - windowFrame.width / 2
            let originY = screenFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        }

        let hostingView = NSHostingView(
            rootView: CaptionOverlayView(transcriptOutput: transcriptOutput)
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
    }

    /// Close the caption overlay.
    func close() {
        panel?.close()
        panel = nil
        isOpen = false
    }
}

/// Custom NSPanel for caption overlay.
private final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
