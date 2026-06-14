import Cocoa
import Combine

/// Monitors global keyboard events for Right Option key hold/release.
/// Uses NSEvent.addGlobalMonitorForEvents for .flagsChanged events.
/// Requires Accessibility permission (same as paste — one permission for everything).
///
/// State machine: Idle → Waiting (hold < threshold) → Recording → Transcribing → Done
@MainActor
final class HotkeyMonitor: ObservableObject {

    // MARK: - Types

    enum MonitorState {
        case idle
        case waiting          // key down, not yet past hold threshold
        case recording        // past threshold, actively recording
    }

    // MARK: - Published State

    @Published private(set) var monitorState: MonitorState = .idle

    let onTriggerRecording = PassthroughSubject<Void, Never>()
    let onStopRecording = PassthroughSubject<Void, Never>()
    let onCancel = PassthroughSubject<Void, Never>()

    // MARK: - Configuration

    var holdThreshold: TimeInterval { AppSettings.shared.dictationHoldThreshold }

    // MARK: - Private State

    private var globalMonitor: Any?
    private var keyDownTime: Date?
    private var holdTimer: Timer?
    private var isKeyDown = false

    /// Distinguish right Option from left Option.
    /// CGEventFlags.maskAlternate = any Option; maskRightAlternate doesn't exist in CGEventFlags.
    /// We use the event's keyCode field via CGEvent (see handleFlagsChanged).
    /// For NSEvent-based approach, we check the keyCode from the underlying CGEvent.
    private func isRightOption(_ event: NSEvent) -> Bool {
        // NSEvent.keyCode is the raw key code. Right Option = 0x3D, Left Option = 0x3A
        return event.keyCode == 0x3D
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        guard globalMonitor == nil else { return true }

        guard AXIsProcessTrusted() else {
            print("[HotkeyMonitor] Accessibility permission not granted — cannot monitor global keys")
            return false
        }

        // Monitor .flagsChanged globally for Right Option press/release
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        if globalMonitor == nil {
            print("[HotkeyMonitor] addGlobalMonitorForEvents returned nil — Accessibility permission needed")
            return false
        }

        print("[HotkeyMonitor] Started — listening for Right Option (flagsChanged)")
        return true
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        holdTimer?.invalidate()
        holdTimer = nil
        monitorState = .idle
        isKeyDown = false
        keyDownTime = nil
    }

    // MARK: - Event Handling

    /// Called on each .flagsChanged event globally.
    private func handleFlagsChanged(_ event: NSEvent) {
        Task { @MainActor [weak self] in
            self?.processFlagsChanged(event)
        }
    }

    private func processFlagsChanged(_ event: NSEvent) {
        guard isRightOption(event) else { return }

        // NSEvent.ModifierFlags doesn't distinguish left/right option.
        // We need to check raw CGEvent flags via CGEvent.
        // Actually, NSEvent.modifierFlags with .option = any option key.
        // For right-only detection, we'd need CGEvent. But for simplicity,
        // let's accept any Option key and check CGEvent if possible.

        // Determine if the right Option key is pressed:
        // For flagsChanged events, keyCode tells which modifier key changed.
        // Right Option = 0x3D, Left Option = 0x3A.
        // We check: is the .option flag set AND keyCode matches right Option?
        let optionDown = event.modifierFlags.contains(.option)

        if optionDown && !isKeyDown {
            handleKeyDown()
        } else if !optionDown && isKeyDown {
            handleKeyUp()
        }
    }

    // MARK: - Key State Machine

    private var dictationMode: String { AppSettings.shared.dictationMode }

    private func handleKeyDown() {
        guard !isKeyDown else { return }
        isKeyDown = true
        keyDownTime = Date()

        if dictationMode == "click" {
            handleClickModeKeyDown()
        } else {
            handleHoldModeKeyDown()
        }
    }

    private func handleKeyUp() {
        guard isKeyDown else { return }
        isKeyDown = false

        print("[HotkeyMonitor] Right Option UP (state: \(monitorState))")

        holdTimer?.invalidate()
        holdTimer = nil

        if dictationMode == "click" {
            // In click mode, key-up does nothing — recording is toggled on key-down
            keyDownTime = nil
            return
        }

        // Hold mode: key-up stops recording
        switch monitorState {
        case .waiting:
            monitorState = .idle
            onCancel.send()
            print("[HotkeyMonitor] → Cancelled (hold too short)")

        case .recording:
            monitorState = .idle
            onStopRecording.send()
            print("[HotkeyMonitor] → Stop recording & transcribe")

        case .idle:
            break
        }

        keyDownTime = nil
    }

    // MARK: - Hold Mode

    private func handleHoldModeKeyDown() {
        let threshold = holdThreshold
        monitorState = .waiting

        if threshold <= 0 {
            // Disabled — start recording immediately
            triggerRecording()
        } else {
            print("[HotkeyMonitor] Right Option DOWN (waiting \(threshold)s for hold)")
            holdTimer = Timer.scheduledTimer(
                withTimeInterval: threshold,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.triggerRecording()
                }
            }
        }
    }

    // MARK: - Click Mode

    private func handleClickModeKeyDown() {
        switch monitorState {
        case .idle:
            // Start recording immediately (bypass triggerRecording's waiting guard)
            print("[HotkeyMonitor] Right Option DOWN — click mode, starting recording")
            monitorState = .recording
            onTriggerRecording.send()

        case .waiting, .recording:
            // Stop recording
            print("[HotkeyMonitor] Right Option DOWN — click mode, stopping recording")
            holdTimer?.invalidate()
            holdTimer = nil
            monitorState = .idle
            onStopRecording.send()
            keyDownTime = nil

        }
    }

    // MARK: - Trigger

    private func triggerRecording() {
        guard isKeyDown, monitorState == .waiting else { return }
        monitorState = .recording
        onTriggerRecording.send()
        print("[HotkeyMonitor] → Recording started")
    }
}
