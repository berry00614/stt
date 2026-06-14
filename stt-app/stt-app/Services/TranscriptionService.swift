import Foundation
import Combine
import SwiftUI

/// Coordinates real-time streaming transcription with incremental send:
///   Audio capture → sliding window → POST whisper-server → diff-based text output
///
/// Anti-hallucination (ported from Python CLI):
///   1. Energy gate (RMS threshold + sustained speech detection)
///   2. whisper no-speech-thold (server-side)
///   3. Hallucination text filter (post-processing)
@MainActor
final class TranscriptionService: ObservableObject {

    // MARK: - State

    @Published private(set) var isRunning = false
    @Published var displayText: String = ""
    @Published private(set) var currentStreamTime: Double = 0

    // MARK: - Configuration

    var streamInterval: TimeInterval { AppSettings.shared.captionsStreamInterval }
    var silenceThreshold: Float { Float(AppSettings.shared.captionsSilenceThreshold) }

    // MARK: - Dependencies

    let serverManager = WhisperServerManager()
    let audioCapture = AudioCaptureService()
    private var cancellables = Set<AnyCancellable>()
    private var streamTimer: Timer?

    // MARK: - Incremental state

    private var lastSentOffset: Int = 0          // byte offset in accumulatedData
    private var lastFullText: String = ""         // full text from last server response
    private var transcriptSegments: [String] = [] // incremental text segments
    private let maxDisplaySegments = 8            // rolling window for display

    // Energy gate
    private var silenceStreak: Int = 0
    private var allowPrint: Bool = false
    private let hangoverIntervals: Int = 3

    // Audio constants
    private let bytesPerSec: Int = 16000 * 2       // 16kHz × 16-bit mono
    private let chunkWindowSec: Int = 5             // send last 5s for context
    private let minChunkBytes: Int = 1600           // 0.05s minimum

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        displayText = ""
        lastFullText = ""
        lastSentOffset = 0
        transcriptSegments = []
        silenceStreak = 0
        allowPrint = false

        // 1. Start whisper-server with stream-optimized model
        print("[Transcription] Starting whisper-server (stream model: \(AppSettings.shared.streamModelName))...")
        await serverManager.start(modelOverride: AppSettings.shared.streamModelName)

        guard serverManager.isReady else {
            print("[Transcription] Server failed to start. State: \(serverManager.serverState)")
            isRunning = false
            return
        }

        // 2. Request microphone permission
        let hasPermission = await audioCapture.requestPermission()
        guard hasPermission else {
            print("[Transcription] Microphone permission denied")
            serverManager.stop()
            isRunning = false
            return
        }

        // 3. Start audio capture
        do {
            try audioCapture.start()
            print("[Transcription] Audio capture started (16kHz mono)")
        } catch {
            print("[Transcription] Audio capture failed: \(error)")
            serverManager.stop()
            isRunning = false
            return
        }

        // 4. Start periodic send timer
        let interval = streamInterval
        print("[Transcription] Sending timer started (interval: \(interval)s, window: \(chunkWindowSec)s)")

        let timer = Timer(
            timeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendChunk()
            }
        }
        streamTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        print("[Transcription] Pipeline started — streaming active")
    }

    func stop() {
        print("[Transcription] Stopping pipeline...")
        isRunning = false
        streamTimer?.invalidate()
        streamTimer = nil
        audioCapture.stop()
        serverManager.stop()
        displayText = ""
        lastFullText = ""
        transcriptSegments = []
        lastSentOffset = 0
        print("[Transcription] Pipeline stopped")
    }

    // MARK: - Chunk Processing (incremental)

    private var chunkCount = 0

    private func sendChunk() async {
        guard isRunning, serverManager.isReady, audioCapture.state == .recording else { return }

        let totalData = audioCapture.accumulatedData
        let totalBytes = totalData.count

        // Guard: not enough audio yet
        guard totalBytes >= minChunkBytes else { return }

        // --- 增量发送：只取上次以来新增的音频 ---
        let newData: Data
        if lastSentOffset > 0 && lastSentOffset < totalBytes {
            newData = totalData.subdata(in: lastSentOffset..<totalBytes)
        } else {
            // First chunk or reset: send the window
            let start = max(0, totalBytes - chunkWindowSec * bytesPerSec)
            newData = totalData.subdata(in: start..<totalBytes)
        }

        guard newData.count >= minChunkBytes else { return }
        lastSentOffset = totalBytes

        // --- 滑动窗口：取最近 N 秒（含上下文）+ 新数据用于转写 ---
        let windowStart = max(0, totalBytes - chunkWindowSec * bytesPerSec)
        let windowData = totalData.subdata(in: windowStart..<totalBytes)

        // --- Energy gate ---
        let hasSpeech = AntiHallucination.hasSpeech(windowData, threshold: silenceThreshold)
        if hasSpeech {
            silenceStreak = 0
            allowPrint = true
        } else {
            silenceStreak += 1
            allowPrint = (silenceStreak <= 1)
            if silenceStreak > hangoverIntervals {
                return  // extended silence — skip entirely
            }
        }

        // --- Send to server ---
        let wav = AntiHallucination.buildWAV(pcmData: windowData)
        chunkCount += 1
        let text = try? await retryTranscribe(wavData: wav, filename: "chunk_\(chunkCount).wav", maxRetries: 2)

        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if chunkCount % 10 == 0 {
            print("[Transcription] Chunk #\(chunkCount): window=\(windowData.count/bytesPerSec)s, "
                  + "new=\(newData.count/bytesPerSec)s, speech=\(hasSpeech), "
                  + "silenceStreak=\(silenceStreak), text=\(trimmed.prefix(50))")
        }

        // --- Filter ---
        guard !trimmed.isEmpty,
              !AntiHallucination.isHallucination(trimmed),
              allowPrint else { return }

        // --- 增量文本累积：diff between current and previous full text ---
        if trimmed.hasPrefix(lastFullText) && trimmed.count > lastFullText.count {
            // New content appended
            let delta = String(trimmed.dropFirst(lastFullText.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !delta.isEmpty {
                let normalized = TextNormalizer.normalize(delta, language: AppSettings.shared.language)
                transcriptSegments.append(normalized)
                print("[Transcription] Δ: \"\(normalized.prefix(60))\"")
            }
        } else if trimmed != lastFullText {
            // Text changed significantly (new utterance), start fresh
            if !trimmed.isEmpty {
                let normalized = TextNormalizer.normalize(trimmed, language: AppSettings.shared.language)
                transcriptSegments = [normalized]
                print("[Transcription] New utterance: \"\(normalized.prefix(60))\"")
            }
        }
        lastFullText = trimmed

        // --- 滚动窗口显示 ---
        let windowSize = min(maxDisplaySegments, transcriptSegments.count)
        let recent = transcriptSegments.suffix(windowSize)
        displayText = recent.joined(separator: " ")

        currentStreamTime = Double(totalBytes) / Double(bytesPerSec)
    }

    // MARK: - Retry

    private func retryTranscribe(wavData: Data, filename: String, maxRetries: Int) async -> String? {
        for attempt in 0..<maxRetries {
            let result = await serverManager.transcribe(wavData: wavData, filename: filename)
            if !result.isEmpty { return result }
            if attempt < maxRetries - 1 {
                print("[Transcription] Retry \(attempt + 1)/\(maxRetries)...")
                try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
            }
        }
        // Last attempt
        return await serverManager.transcribe(wavData: wavData, filename: filename)
    }
}
