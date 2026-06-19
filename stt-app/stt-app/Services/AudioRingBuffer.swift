import Foundation

/// Synchronized Single-Producer Single-Consumer (SPSC) ring buffer for f32 PCM audio.
///
/// The audio capture thread writes samples; the WhisperEngine actor thread reads them.
/// Fixed pre-allocated capacity — no heap allocation on the write path.
/// When full, the oldest samples are silently overwritten (newest audio is preferred).
///
/// Thread safety: uses one `os_unfair_lock` to publish sample data and index
/// updates atomically. A reader can never observe a write before its samples
/// have been copied into storage.
/// Marked @unchecked Sendable because all methods are internally synchronized.
nonisolated final class AudioRingBuffer: @unchecked Sendable {
    /// Total capacity in samples (e.g. 480,000 for 30 seconds at 16kHz).
    let capacity: Int

    /// Pre-allocated storage.
    private let buffer: UnsafeMutableBufferPointer<Float>

    /// Monotonically increasing total samples written (never wraps).
    private var _totalWritten: Int = 0

    /// Current read position (monotonically increasing, always ≤ totalWritten).
    private var _totalRead: Int = 0

    private var lock = os_unfair_lock()

    // MARK: - Init

    /// - Parameter capacityInSamples: Maximum number of float samples the ring buffer can hold.
    ///   Example: 30 seconds × 16000 Hz = 480,000 samples ≈ 1.92 MB.
    init(capacityInSamples: Int) {
        precondition(capacityInSamples > 0, "AudioRingBuffer capacity must be positive")
        self.capacity = capacityInSamples
        self.buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacityInSamples)
        self.buffer.initialize(repeating: 0.0)
    }

    deinit {
        buffer.deinitialize()
        buffer.deallocate()
    }

    // MARK: - Write (Audio Thread)

    /// Write float samples to the ring buffer. Called from the audio capture thread.
    /// - Parameter samples: The f32 PCM samples to write.
    /// - Returns: The number of samples actually written (always equals samples.count).
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        return samples.withUnsafeBufferPointer { ptr in
            write(ptr)
        }
    }

    /// Write float samples from an unsafe buffer pointer.
    @discardableResult
    func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let inputCount = samples.count
        guard inputCount > 0 else { return 0 }

        // If one callback contains more than the entire capacity, only the
        // newest samples can be retained.
        let count = min(inputCount, capacity)
        let sourceOffset = inputCount - count

        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let writeIdx = _totalWritten % capacity

        // Copy samples into the ring buffer, handling wrap-around
        let firstPart = min(count, capacity - writeIdx)
        let base = buffer.baseAddress!

        // Copy first part (from writeIdx to end of buffer or count)
        for i in 0..<firstPart {
            base[writeIdx + i] = samples[sourceOffset + i]
        }

        // Copy remaining (wrapped around to beginning)
        if firstPart < count {
            let remaining = count - firstPart
            for i in 0..<remaining {
                base[i] = samples[sourceOffset + firstPart + i]
            }
        }

        _totalWritten &+= count

        // Drop overwritten audio so the next read starts at the oldest sample
        // that is still present in the fixed-size storage.
        let oldestRetained = _totalWritten - capacity
        if _totalRead < oldestRetained {
            _totalRead = oldestRetained
        }

        return inputCount
    }

    // MARK: - Read (WhisperEngine Thread)

    /// Read available samples into the provided array.
    /// - Parameter out: Pre-allocated array to fill with samples.
    /// - Parameter maxCount: Maximum number of samples to read.
    /// - Returns: Number of samples actually read.
    func read(into out: inout [Float], maxCount: Int) -> Int {
        guard maxCount > 0, !out.isEmpty else { return 0 }

        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let available = _totalWritten - _totalRead
        let count = min(maxCount, available, out.count)
        guard count > 0 else { return 0 }

        let readIdx = _totalRead % capacity

        let base = buffer.baseAddress!

        // Copy from ring buffer, handling wrap-around
        let firstPart = min(count, capacity - readIdx)
        for i in 0..<firstPart {
            out[i] = base[readIdx + i]
        }

        if firstPart < count {
            let remaining = count - firstPart
            for i in 0..<remaining {
                out[firstPart + i] = base[i]
            }
        }

        _totalRead &+= count
        return count
    }

    /// Read `maxCount` samples, returning them in a new array.
    func read(maxCount: Int) -> [Float] {
        let count = min(maxCount, availableSamples)
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let read = read(into: &out, maxCount: count)
        if read < count {
            out.removeLast(count - read)
        }
        return out
    }

    /// Discard the specified number of samples from the front of the buffer.
    func discard(_ count: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let toDiscard = min(count, _totalWritten - _totalRead)
        guard toDiscard > 0 else { return }
        _totalRead &+= toDiscard
    }

    // MARK: - State

    /// Number of samples currently available for reading.
    var availableSamples: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _totalWritten - _totalRead
    }

    /// Total number of samples written since creation (monotonic, never wraps).
    var totalWritten: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _totalWritten
    }

    /// Reset the buffer to empty state.
    func reset() {
        os_unfair_lock_lock(&lock)
        _totalWritten = 0
        _totalRead = 0
        os_unfair_lock_unlock(&lock)
    }
}
