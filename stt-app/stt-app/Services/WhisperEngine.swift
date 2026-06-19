import Darwin
import Foundation

/// Swift actor wrapping the whisper.cpp C API for in-process speech-to-text.
///
/// All whisper C API calls happen on the actor's serial executor, ensuring
/// thread safety (whisper.cpp requires single-threaded access per context).
///
/// Architecture:
///   1. Reads f32 PCM audio from AudioRingBuffer (audio thread writes, actor reads)
///   2. Runs VAD gating (Silero neural VAD or energy-based fallback)
///   3. Processes speech through whisper_full() with sliding window
///   4. Emits transcript text via onTranscript callback
actor WhisperEngine {

    // MARK: - State

    enum State: Equatable {
        case idle
        case loading
        case ready
        case error(String)
    }

    /// Current engine state.
    var state: State = .idle

    /// Whether speech is currently being detected/transcribed.
    var isSpeaking: Bool = false

    // MARK: - Audio Source

    private let ringBuffer: AudioRingBuffer

    // MARK: - whisper.cpp Contexts

    private var ctx: OpaquePointer?           // whisper_context *
    private var vadCtx: OpaquePointer?        // whisper_vad_context (optional)

    // MARK: - Configuration

    private var language: String = "auto"

    /// Sliding window parameters (in milliseconds).
    private var stepMs: Int = 1500     // process every 1.5s of new audio (lower = less latency)
    private var lengthMs: Int = 10000  // keep 10s context window
    private var keepMs: Int = 200      // 200ms overlap between windows

    /// Number of threads for inference.
    private var nThreads: Int = 4

    // MARK: - Processing State

    private var isRunning = false

    /// Heap-allocated abort flag. The C abort callback reads this address.
    private var abortFlag: UnsafeMutablePointer<Int32>

    /// Internal buffer holding the sliding window of audio (last lengthSamples samples).
    private var pcmf32Buffer: [Float] = []

    /// Prompt tokens from previous inference for context chaining.
    private var promptTokens: [whisper_token] = []

    // MARK: - Callbacks

    /// Called with each new transcript segment (from the actor's executor).
    var onTranscript: ((String) -> Void)?

    /// Called when engine state changes.
    var onStateChange: ((State) -> Void)?

    /// Called when speaking state changes.
    var onSpeakingChange: ((Bool) -> Void)?

    // MARK: - Init

    init(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer

        // Allocate heap memory for the abort flag (must have a stable address
        // since it's passed as user_data to the C abort callback).
        self.abortFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.abortFlag.initialize(to: 0)
    }

    deinit {
        // Free abort flag
        abortFlag.deinitialize(count: 1)
        abortFlag.deallocate()

        // Free whisper context
        if let ctx = ctx {
            whisper_free(ctx)
        }

        // Free VAD context
        if let vctx = vadCtx {
            whisper_vad_free(vctx)
        }

        print("[WhisperEngine] Deinitialized")
    }

    // MARK: - Lifecycle

    /// Load the whisper model and optionally a VAD model.
    /// - Parameters:
    ///   - modelPath: Path to the whisper ggml model (e.g. ggml-small.bin).
    ///   - vadModelPath: Optional path to Silero VAD ggml model. If nil, falls back to energy-based VAD.
    ///   - language: Language code ("zh", "en", "auto"). Default "auto".
    /// - Throws: WhisperError if model loading fails.
    func loadModel(modelPath: String, vadModelPath: String? = nil, language: String = "auto") throws {
        setState(.loading)

        // Save configuration
        self.language = language

        // --- Load whisper model ---
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true       // Metal / CoreML acceleration
        cparams.flash_attn = true    // Flash attention for speed

        guard let ctx = modelPath.withCString({ whisper_init_from_file_with_params($0, cparams) }) else {
            setState(.error("Failed to load whisper model: \(modelPath)"))
            throw WhisperError.initFailed(modelPath)
        }
        self.ctx = ctx

        // --- Load VAD model (optional) ---
        if let vadPath = vadModelPath {
            let vadCParams = whisper_vad_default_context_params()
            if let vad = vadPath.withCString({ whisper_vad_init_from_file_with_params($0, vadCParams) }) {
                self.vadCtx = vad
                print("[WhisperEngine] VAD model loaded: \(vadPath)")
            } else {
                // Non-fatal: VAD failed, will use energy-based fallback
                print("[WhisperEngine] VAD model failed to load, using energy-based fallback")
            }
        } else {
            print("[WhisperEngine] No VAD model path provided, using energy-based fallback")
        }

        setState(.ready)
        print("[WhisperEngine] Model loaded: \(modelPath)")
    }

    /// Start the processing loop. Model must be loaded first.
    func start() {
        guard case .ready = state else {
            print("[WhisperEngine] Cannot start: state is \(state)")
            return
        }
        guard !isRunning else { return }

        isRunning = true
        abortFlag.pointee = 0
        pcmf32Buffer = []
        promptTokens = []

        // Launch the processing loop as a detached task on this actor
        Task {
            await processLoop()
        }
    }

    /// Stop the processing loop and abort any in-progress inference.
    func stop() {
        isRunning = false
        abortFlag.pointee = 1  // Signal C abort callback
        // Reset VAD state for next utterance
        if let vctx = vadCtx {
            whisper_vad_reset_state(vctx)
        }
    }

    // MARK: - State Updates

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private func setSpeaking(_ speaking: Bool) {
        if isSpeaking != speaking {
            isSpeaking = speaking
            onSpeakingChange?(speaking)
        }
    }

    // MARK: - Processing Loop

    /// The main processing loop. Runs on the actor's serial executor.
    private func processLoop() async {
        let stepSamples = stepMs * 16000 / 1000      // e.g. 3s = 48000 samples
        let lengthSamples = lengthMs * 16000 / 1000   // e.g. 10s = 160000 samples
        // keepSamples handled implicitly by keeping last lengthSamples

        var silenceCount = 0
        let maxSilenceSteps = 6  // After ~18s of silence (6 × 3s steps), pause processing

        while isRunning {
            // 1. Wait for enough audio in ring buffer
            let available = ringBuffer.availableSamples
            if available < stepSamples {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                continue
            }

            // 2. Read step samples from ring buffer
            let newAudio = ringBuffer.read(maxCount: stepSamples)
            guard !newAudio.isEmpty else { continue }

            // 3. Append to internal buffer and trim to window
            pcmf32Buffer.append(contentsOf: newAudio)
            if pcmf32Buffer.count > lengthSamples {
                pcmf32Buffer.removeFirst(pcmf32Buffer.count - lengthSamples)
            }

            // Guard: need at least 1s of audio for meaningful inference
            guard pcmf32Buffer.count >= 16000 else { continue }

            // 4. VAD gating: check for speech in recent audio
            let hasSpeech = detectSpeech(samples: newAudio)

            if hasSpeech {
                silenceCount = 0
                setSpeaking(true)

                // 5. Run inference on the sliding window
                do {
                    let text = try runInference(samples: pcmf32Buffer)
                    if !text.isEmpty {
                        onTranscript?(text)
                    }
                } catch {
                    if case WhisperError.aborted = error {
                        break // Exit the loop
                    }
                    print("[WhisperEngine] Inference error: \(error)")
                }
            } else {
                silenceCount += 1
                // If prolonged silence, mark as not speaking
                if silenceCount >= maxSilenceSteps && isSpeaking {
                    setSpeaking(false)
                    // Reset prompt tokens at utterance boundary
                    promptTokens = []
                    // Clear internal buffer to start fresh
                    pcmf32Buffer = []
                }
            }

            // Yield occasionally to avoid blocking the actor
            await Task.yield()
        }

        setSpeaking(false)
        print("[WhisperEngine] Processing loop exited")
    }

    // MARK: - Inference

    /// Run whisper_full() on the provided f32 PCM samples.
    private func runInference(samples: [Float]) throws -> String {
        guard let ctx = ctx else {
            throw WhisperError.notInitialized
        }

        // Check abort flag
        if abortFlag.pointee != 0 {
            throw WhisperError.aborted
        }

        // Build whisper_full_params
        var wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        // Core parameters
        wparams.strategy = WHISPER_SAMPLING_GREEDY
        wparams.n_threads = Int32(nThreads)
        wparams.single_segment = true    // force single segment (useful for streaming)
        wparams.no_timestamps = true     // skip timestamp tokens
        wparams.no_context = false       // chain previous context
        wparams.print_special = false
        wparams.print_progress = false
        wparams.print_realtime = false
        wparams.print_timestamps = false

        // Language
        wparams.language = nil
        wparams.detect_language = false
        if language != "auto" {
            wparams.language = UnsafePointer(strdup(language))
        }

        // Speed/quality
        wparams.suppress_blank = true
        wparams.suppress_nst = true
        wparams.temperature = 0.0
        wparams.max_initial_ts = 1.0
        wparams.length_penalty = -1.0
        wparams.temperature_inc = 0.2
        wparams.entropy_thold = 2.4
        wparams.logprob_thold = -1.0
        wparams.no_speech_thold = 0.6

        // Context chaining: pass accumulated prompt tokens
        var promptPtr: UnsafePointer<whisper_token>? = nil
        var promptCount: Int32 = 0
        if !promptTokens.isEmpty {
            promptPtr = promptTokens.withUnsafeBufferPointer { $0.baseAddress }
            promptCount = Int32(promptTokens.count)
        }

        // Abort callback
        wparams.abort_callback = whisper_abort_callback_trampoline
        wparams.abort_callback_user_data = UnsafeMutableRawPointer(abortFlag)

        // Run inference
        let result: Int32 = samples.withUnsafeBufferPointer { samplePtr in
            var wp = wparams
            wp.prompt_tokens = promptPtr
            wp.prompt_n_tokens = promptCount
            return whisper_full(ctx, wp, samplePtr.baseAddress, Int32(samples.count))
        }

        // Clean up
        if wparams.language != nil && language != "auto" {
            free(UnsafeMutableRawPointer(mutating: wparams.language))
        }

        // Check result
        if abortFlag.pointee != 0 {
            throw WhisperError.aborted
        }
        guard result == 0 else {
            throw WhisperError.inferenceFailed(Int(result))
        }

        // Extract text from all segments
        let nSegments = Int(whisper_full_n_segments(ctx))
        var text = ""

        for i in 0..<nSegments {
            if let segmentText = whisper_full_get_segment_text(ctx, Int32(i)) {
                text += String(cString: segmentText)
            }
        }

        // Store prompt tokens for next inference (context chaining)
        var newTokens: [whisper_token] = []
        for i in 0..<nSegments {
            let nTokens = Int(whisper_full_n_tokens(ctx, Int32(i)))
            for j in 0..<nTokens {
                let tokenId = whisper_full_get_token_id(ctx, Int32(i), Int32(j))
                newTokens.append(tokenId)
            }
        }
        promptTokens = newTokens

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - VAD

    /// Detect whether speech is present in the given audio samples.
    /// Returns true if speech is detected.
    private func detectSpeech(samples: [Float]) -> Bool {
        // If Silero VAD is loaded, use neural VAD
        if let vctx = vadCtx {
            return samples.withUnsafeBufferPointer { ptr in
                whisper_vad_detect_speech_no_reset(vctx, ptr.baseAddress, Int32(ptr.count))
            }
        }

        // Fallback: energy-based VAD using AntiHallucination.hasSpeech
        // Convert f32 to Int16 for the existing energy gate
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767.0)
        }
        let int16Data = Data(bytes: int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size)
        return AntiHallucination.hasSpeech(int16Data, threshold: 0.01, minFrames: 5)
    }
}

// MARK: - Errors

enum WhisperError: Error, LocalizedError {
    case notInitialized
    case modelNotFound(String)
    case initFailed(String)
    case inferenceFailed(Int)
    case aborted

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperEngine not initialized"
        case .modelNotFound(let path):
            return "Model not found: \(path)"
        case .initFailed(let path):
            return "Failed to load model: \(path)"
        case .inferenceFailed(let code):
            return "Inference failed with code \(code)"
        case .aborted:
            return "Inference aborted"
        }
    }
}
