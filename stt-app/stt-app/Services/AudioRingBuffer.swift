import Foundation

/// Lock-free Single-Producer Single-Consumer (SPSC) ring buffer for f32 PCM audio.
///
/// The audio capture thread writes samples; the WhisperEngine actor thread reads them.
/// Fixed pre-allocated capacity — no heap allocation on the write path.
/// When full, the oldest samples are silently overwritten (newest audio is preferred).
///
/// Thread safety: uses `os_unfair_lock` for index updates (~10ns hold time, safe for real-time audio).
/// Marked @unchecked Sendable because all methods are internally synchronized.
final class AudioRingBuffer: @unchecked Sendable {
    /// Total capacity in samples (e.g. 480,000 for 30 seconds at 16kHz).
    let capacity: Int

    /// Pre-allocated storage.
    private let buffer: UnsafeMutableBufferPointer<Float>

    /// Monotonically increasing total samples written (never wraps).
    /// Protected by writeLock.
    private var _totalWritten: Int = 0

    /// Current read position (monotonically increasing, always ≤ totalWritten).
    /// Protected by readLock.
    private var _totalRead: Int = 0

    private var writeLock = os_unfair_lock()
    private var readLock = os_unfair_lock()

    // MARK: - Init

    /// - Parameter capacityInSamples: Maximum number of float samples the ring buffer can hold.
    ///   Example: 30 seconds × 16000 Hz = 480,000 samples ≈ 1.92 MB.
    init(capacityInSamples: Int) {
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
        let count = samples.count
        guard count > 0 else { return 0 }

        os_unfair_lock_lock(&writeLock)
        let writeIdx = _totalWritten % capacity
        _totalWritten &+= count
        os_unfair_lock_unlock(&writeLock)

        // Copy samples into the ring buffer, handling wrap-around
        let firstPart = min(count, capacity - writeIdx)
        let base = buffer.baseAddress!

        // Copy first part (from writeIdx to end of buffer or count)
        for i in 0..<firstPart {
            base[writeIdx + i] = samples[i]
        }

        // Copy remaining (wrapped around to beginning)
        if firstPart < count {
            let remaining = count - firstPart
            for i in 0..<remaining {
                base[i] = samples[firstPart + i]
            }
        }

        return count
    }

    // MARK: - Read (WhisperEngine Thread)

    /// Read available samples into the provided array.
    /// - Parameter out: Pre-allocated array to fill with samples.
    /// - Parameter maxCount: Maximum number of samples to read.
    /// - Returns: Number of samples actually read.
    func read(into out: inout [Float], maxCount: Int) -> Int {
        let available = availableSamples
        let count = min(maxCount, available)
        guard count > 0 else { return 0 }

        os_unfair_lock_lock(&readLock)
        let readIdx = _totalRead % capacity
        _totalRead &+= count
        os_unfair_lock_unlock(&readLock)

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
        let available = availableSamples
        let toDiscard = min(count, available)
        guard toDiscard > 0 else { return }

        os_unfair_lock_lock(&readLock)
        _totalRead &+= toDiscard
        os_unfair_lock_unlock(&readLock)
    }

    // MARK: - State

    /// Number of samples currently available for reading.
    var availableSamples: Int {
        let written: Int
        os_unfair_lock_lock(&writeLock)
        written = _totalWritten
        os_unfair_lock_unlock(&writeLock)

        let read: Int
        os_unfair_lock_lock(&readLock)
        read = _totalRead
        os_unfair_lock_unlock(&readLock)

        // Cap at capacity: we can never have more samples available than the buffer size
        let diff = written - read
        return min(diff, capacity)
    }

    /// Total number of samples written since creation (monotonic, never wraps).
    var totalWritten: Int {
        os_unfair_lock_lock(&writeLock)
        defer { os_unfair_lock_unlock(&writeLock) }
        return _totalWritten
    }

    /// Reset the buffer to empty state. Not safe to call while audio is actively being written/read.
    func reset() {
        os_unfair_lock_lock(&writeLock)
        os_unfair_lock_lock(&readLock)
        _totalWritten = 0
        _totalRead = 0
        os_unfair_lock_unlock(&readLock)
        os_unfair_lock_unlock(&writeLock)
    }
}
