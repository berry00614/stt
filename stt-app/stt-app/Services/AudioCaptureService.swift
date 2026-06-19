import AVFAudio
import Combine
import Foundation

/// Wraps AVAudioEngine for microphone audio capture.
/// Supports both continuous capture (for live captions) and
/// timed recording to a buffer (for dictation).
@MainActor
final class AudioCaptureService: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case recording
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentRMS: Float = 0.0

    // MARK: - Engine

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000.0

    /// The accumulated PCM data buffer (for dictation recording).
    private(set) var accumulatedData = Data()

    /// Callback for streaming audio chunks — Int16 PCM (called from audio tap thread).
    /// Used by DictationService.
    var onAudioChunk: ((Data) -> Void)?

    /// Callback for streaming float32 audio chunks (called from audio tap thread).
    /// Used by LiveCaptionService (whisper.cpp expects f32 samples).
    var onAudioChunkFloats: (([Float]) -> Void)?

    // MARK: - Lifecycle

    /// Request microphone permission. Must be called before start().
    func requestPermission() async -> Bool {
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Start continuous audio capture.
    func start() throws {
        guard state == .idle else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // We want 16kHz mono f32 for whisper.cpp C API.
        // The input format from the mic may differ (e.g. 48kHz float32),
        // so we install a converter tap.
        // Int16 data for DictationService is derived from the f32 output.
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            state = .error("Failed to create audio format")
            throw AudioError.formatCreationFailed
        }

        // Install a converter if input format differs from desired output
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            state = .error("Failed to create audio converter")
            throw AudioError.converterCreationFailed
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.processBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }

        try engine.start()
        state = .recording
    }

    /// Stop audio capture.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .idle
    }

    /// Reset accumulated data buffer (for dictation).
    func resetBuffer() {
        accumulatedData = Data()
    }

    // MARK: - Buffer Processing

    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) {
        // Calculate output buffer capacity
        let inputFrames = buffer.frameLength
        let outputFrames = AVAudioFrameCount(
            Double(inputFrames) * sampleRate / buffer.format.sampleRate
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrames
        ) else { return }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(
            to: outputBuffer,
            error: &error,
            withInputFrom: inputBlock
        )

        if let error = error {
            DispatchQueue.main.async { [weak self] in
                self?.state = .error(error.localizedDescription)
            }
            return
        }

        // Extract f32 PCM data from output buffer
        guard let floatChannelData = outputBuffer.floatChannelData else { return }
        let frameCount = Int(outputBuffer.frameLength)
        let floats = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameCount))

        // Convert f32 → Int16 for DictationService backward compatibility
        var int16Samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, floats[i]))
            int16Samples[i] = Int16(clamped * 32767.0)
        }
        let int16Data = Data(bytes: int16Samples, count: frameCount * MemoryLayout<Int16>.size)

        // Update accumulated buffer (for dictation)
        accumulatedData.append(int16Data)

        // Update RMS from Int16 data
        let rms = AntiHallucination.audioRMS(int16Data)
        DispatchQueue.main.async { [weak self] in
            self?.currentRMS = rms
        }

        // Forward to streaming consumers
        onAudioChunk?(int16Data)
        onAudioChunkFloats?(floats)
    }
}

// MARK: - Errors

enum AudioError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create 16kHz mono PCM format"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        }
    }
}
