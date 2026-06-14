import Foundation

/// Port of the Python stt CLI's hallucination detection logic.
/// Filters out whisper's noise-induced garbage text (sound-effect descriptions,
/// YouTube-style subtitle artifacts, replacement characters, etc.).
enum AntiHallucination {

    // MARK: - Hallucination patterns

    /// Markers that indicate the text is a hallucinated sound-effect description
    /// or YouTube/subtitle artifact, not real speech.
    private static let hallucinationSubstrings: Set<String> = [
        // English sound effects
        "(crickets", "(scissors", "(keyboard", "(typing", "(phone",
        "(silence", "(wind", "(footsteps", "(music", "(breathing",
        "(applause", "(laughter", "(sigh", "(cough", "(sneeze",
        "[BLANK_AUDIO]", "[ Silence ]", "[Subscribe]",
        // Chinese YouTube / subtitle artifacts
        "字幕", "製作", "字幕製作", "熱點預測",
        "订阅", "訂閱", "点赞", "点讚", "分享",
        "关注", "關注", "一键三连", "弹幕",
        "字幕由", "自动生成", "自动生成字幕",
    ]

    /// Regex matching any parenthetical/bracket segment: (...), [...], （...）, 【...】
    private static let parenPattern = try! NSRegularExpression(
        pattern: #"[\(\[（【][^\)\]）】]*[\)\]）】]"#,
        options: []
    )

    // MARK: - Audio energy

    /// Root mean square energy of 16-bit PCM audio (0.0 = silence).
    /// Port of `_audio_rms()` in stt.
    static func audioRMS(_ pcmData: Data) -> Float {
        guard pcmData.count >= 2 else { return 0.0 }
        let samples = pcmData.withUnsafeBytes { ptr -> [Int16] in
            let count = pcmData.count / 2
            let raw = ptr.bindMemory(to: Int16.self)
            return Array(raw.prefix(count))
        }
        guard !samples.isEmpty else { return 0.0 }
        let sumSquares = samples.reduce(0) { acc, s in
            acc + Int64(s) * Int64(s)
        }
        let rms = sqrt(Float(sumSquares) / Float(samples.count))
        return rms / 32768.0
    }

    /// True if enough 0.1s frames exceed threshold (requires sustained speech).
    /// Port of `_has_speech()` in stt.
    static func hasSpeech(
        _ pcmData: Data,
        threshold: Float = 0.01,
        minFrames: Int = 5
    ) -> Bool {
        guard pcmData.count >= 3200 else {
            return audioRMS(pcmData) > threshold
        }
        let frameLen = 1600  // 0.1s at 16kHz mono s16le
        var above = 0
        var offset = 0

        while offset + frameLen <= pcmData.count {
            let frame = pcmData.subdata(in: offset..<(offset + frameLen))
            if audioRMS(frame) > threshold {
                above += 1
                if above >= minFrames {
                    return true
                }
            } else {
                above = 0  // reset on silent frame (requires consecutive)
            }
            offset += frameLen / 2  // 50% overlap
        }
        return false
    }

    // MARK: - Hallucination detection

    /// Heuristic: detect whisper hallucination from silence/noise.
    /// Port of `_is_hallucination()` in stt.
    static func isHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return true }

        // Entire text is a parenthetical sound-effect description
        if t.hasPrefix("(") && t.hasSuffix(")") { return true }
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }

        // Scan parenthetical segments anywhere in the text
        let nsRange = NSRange(t.startIndex..<t.endIndex, in: t)
        let matches = parenPattern.matches(in: t, options: [], range: nsRange)
        for match in matches {
            guard let range = Range(match.range, in: t) else { continue }
            let seg = String(t[range])
            for marker in hallucinationSubstrings {
                if seg.contains(marker) { return true }
            }
        }

        // Check full text for markers
        for marker in hallucinationSubstrings {
            if t.contains(marker) { return true }
        }

        // Garbage: contains replacement characters
        if t.contains("\u{FFFD}") { return true }

        // Count suspicious characters (non-Latin/CJK scripts)
        var suspicious = 0
        for ch in t {
            let cp = ch.unicodeScalars.first?.value ?? 0
            if cp < 0x0020 { continue }
            if 0x0020 <= cp && cp <= 0x024F { continue }  // Latin + IPA
            if 0x3000 <= cp && cp <= 0x9FFF { continue }  // CJK
            if 0xFF00 <= cp && cp <= 0xFFEF { continue }  // Fullwidth forms
            if 0x2000 <= cp && cp <= 0x206F { continue }  // General punctuation
            if cp == 0x3000 { continue }  // IDEOGRAPHIC SPACE
            suspicious += 1
        }
        if suspicious >= 3 && t.count < 20 { return true }

        return false
    }

    // MARK: - WAV helpers

    /// Build a WAV container around raw PCM s16le data.
    /// Port of `_build_wav()` in stt.
    nonisolated static func buildWAV(pcmData: Data, sampleRate: Int32 = 16000) -> Data {
        let dataLen = UInt32(pcmData.count)
        let byteRate = UInt32(sampleRate) * 2  // 1 channel × 2 bytes
        var wav = Data()

        // RIFF header
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: (36 + dataLen).littleEndian) { Data($0) })
        wav.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })  // chunk size
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // PCM
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })   // mono
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })   // block align
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })  // bits per sample

        // data chunk
        wav.append("data".data(using: .ascii)!)
        wav.append(contentsOf: withUnsafeBytes(of: dataLen.littleEndian) { Data($0) })
        wav.append(pcmData)

        return wav
    }
}
