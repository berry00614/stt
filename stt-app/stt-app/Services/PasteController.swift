import Cocoa

/// Handles text insertion at cursor via clipboard + simulated Cmd+V.
/// Requires Accessibility permission (PostEvent entitlement).
enum PasteController {

    /// Paste the given text at the current cursor position.
    /// 1. Saves current clipboard contents
    /// 2. Places text on clipboard
    /// 3. Simulates Cmd+V keypress
    /// 4. Restores original clipboard contents
    static func pasteAtCursor(_ text: String) async {
        guard !text.isEmpty else { return }

        // Check accessibility permission
        guard CGPreflightPostEventAccess() else {
            // Permission not granted — at least copy to clipboard
            copyToClipboard(text)
            return
        }

        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        // Place text on clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Brief yield for clipboard to settle
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Simulate Cmd+V
        simulateCmdV()

        // Restore old clipboard after paste completes
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        if let old = oldContents {
            pasteboard.clearContents()
            pasteboard.setString(old, forType: .string)
        }
    }

    /// Just copy text to clipboard (no paste).
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Simulate Cmd+V keypress via CGEventPost.
    private static func simulateCmdV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        // Key-down
        if let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,  // 'V' key
            keyDown: true
        ) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        // Key-up (CGEvent posts are processed synchronously; the brief
        // interval between down and up is implicit in the event loop)
        if let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,
            keyDown: false
        ) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Check if paste permission is available.
    static var hasPastePermission: Bool {
        return CGPreflightPostEventAccess()
    }

    /// Request paste (Accessibility) permission.
    /// This triggers the system TCC prompt.
    static func requestPastePermission() {
        _ = CGRequestPostEventAccess()
    }
}
