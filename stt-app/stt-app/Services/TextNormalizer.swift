import Foundation

/// Lightweight rule-based text normalization for whisper output.
/// Fixes common whisper error patterns without any external dependencies.
///
/// Whisper's errors are regular and predictable — rules cover the majority:
///   - Repeated phrases (low-confidence hallucination)
///   - Missing sentence capitalization
///   - Punctuation normalization (mixed Chinese/English marks)
///   - Common English homophone swaps
///   - Extra whitespace / broken spacing
enum TextNormalizer {

    // MARK: - Public

    /// Apply all normalization rules based on language.
    static func normalize(_ text: String, language: String = "auto") -> String {
        guard !text.isEmpty else { return text }

        var result = text

        result = fixRepeatedPhrases(result)
        result = capitalizeSentences(result)
        result = normalizePunctuation(result)
        result = fixCommonHomophones(result)
        result = collapseWhitespace(result)

        if language.hasPrefix("zh") {
            result = chineseFixes(result)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Repeated phrase detection

    /// Detect and collapse repeated 2-4 word phrases (common whisper pattern).
    /// Example: "I think I think that's right" → "I think that's right"
    private static func fixRepeatedPhrases(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count >= 4 else { return text }

        var result: [Substring] = []
        var i = 0

        while i < words.count {
            result.append(words[i])

            // Check for repeated phrase starting at i+1
            for phraseLen in [2, 3] {
                let end = i + phraseLen
                let nextEnd = end + phraseLen
                guard nextEnd <= words.count else { continue }

                let phrase = words[i..<end]
                let nextPhrase = words[end..<nextEnd]

                if Array(phrase) == Array(nextPhrase) {
                    // Skip the repetition
                    i = end - 1
                    break
                }
            }
            i += 1
        }

        return result.joined(separator: " ")
    }

    // MARK: - Sentence capitalization

    private static func capitalizeSentences(_ text: String) -> String {
        // Split by sentence boundaries and capitalize each
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?。！？"))
        guard sentences.count > 1 else {
            // Single sentence: just capitalize first letter
            guard let first = text.first, first.isLowercase else { return text }
            return text.prefix(1).uppercased() + text.dropFirst()
        }

        // Process multi-sentence text
        let delimiters = text.filter { ".!?。！？".contains($0) }
        var result = ""
        for (i, sentence) in sentences.enumerated() {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let fixed: String
            if let first = trimmed.first, first.isLowercase {
                fixed = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            } else {
                fixed = trimmed
            }

            result += fixed
            if i < delimiters.count {
                result += String(delimiters[delimiters.index(delimiters.startIndex, offsetBy: min(i, delimiters.count - 1))])
                result += " "
            }
        }

        return result.isEmpty ? text : result
    }

    // MARK: - Punctuation normalization

    /// Normalize mixed Chinese/English punctuation and spacing around marks.
    private static func normalizePunctuation(_ text: String) -> String {
        var result = text

        // Remove space before punctuation (Chinese style)
        let spaceBeforeReplacements = [
            " ,": ",", " .": ".", " !": "!", " ?": "?",
            " 。": "。", " ，": "，", " ！": "！", " ？": "？"
        ]
        for (from, to) in spaceBeforeReplacements {
            result = result.replacingOccurrences(of: from, with: to)
        }

        // Ensure space after English punctuation (word boundaries)
        // Note: must escape regex metacharacters (especially ".")
        for mark in [".", ",", "!", "?", ";", ":"] {
            let escaped = NSRegularExpression.escapedPattern(for: mark)
            result = result.replacingOccurrences(
                of: escaped,
                with: "\(mark) ",
                options: .regularExpression
            )
        }
        // Fix double spaces created above for Chinese context
        result = result.replacingOccurrences(of: "。 ", with: "。")
        result = result.replacingOccurrences(of: "， ", with: "，")

        // Fix: "word.word" → "word. word"
        let joinedDotPattern = try! NSRegularExpression(
            pattern: #"(\w)\.(\w)"#,
            options: []
        )
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = joinedDotPattern.stringByReplacingMatches(
            in: result,
            options: [],
            range: range,
            withTemplate: "$1. $2"
        )

        return result
    }

    // MARK: - Common homophones (English)

    /// Fix very common English homophone errors with high confidence.
    /// Only fixes cases where whisper consistently gets it wrong.
    private static let homophoneFixes: [(String, String)] = [
        ("its a", "it's a"),
        ("its not", "it's not"),
        ("its the", "it's the"),
        ("wont", "won't"),
        ("cant", "can't"),
        ("dont", "don't"),
        ("didnt", "didn't"),
        ("isnt", "isn't"),
        ("arent", "aren't"),
        ("couldnt", "couldn't"),
        ("wouldnt", "wouldn't"),
        ("shouldnt", "shouldn't"),
        ("im ", "I'm "),
        ("ive ", "I've "),
        ("ill ", "I'll "),
    ]

    private static func fixCommonHomophones(_ text: String) -> String {
        var result = text
        for (wrong, correct) in homophoneFixes {
            // Case-insensitive but preserve position
            if result.lowercased().contains(wrong) {
                // Simple replace for exact matches at word boundaries
                if let range = result.range(of: wrong, options: .caseInsensitive) {
                    // Only fix if it's at word start boundary
                    if range.lowerBound == result.startIndex
                       || result[result.index(before: range.lowerBound)] == " " {
                        result.replaceSubrange(range, with: correct)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Chinese fixes

    private static func chineseFixes(_ text: String) -> String {
        var result = text

        // 繁→简：macOS 内置 ICU 转换（Hant-Hans = Traditional → Simplified）
        if let simplified = result.applyingTransform(
            StringTransform(rawValue: "Hant-Hans"),
            reverse: false
        ) {
            result = simplified
        }

        // Fix common Chinese-English mix: remove stray spaces between CJK chars
        let cjkSpacePattern = try! NSRegularExpression(
            pattern: #"([\x{4E00}-\x{9FFF}\x{3000}-\x{303F}\x{FF00}-\x{FFEF}])\s+([\x{4E00}-\x{9FFF}\x{3000}-\x{303F}\x{FF00}-\x{FFEF}])"#,
            options: []
        )
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = cjkSpacePattern.stringByReplacingMatches(
            in: result,
            options: [],
            range: range,
            withTemplate: "$1$2"
        )

        return result
    }

    // MARK: - Whitespace

    private static func collapseWhitespace(_ text: String) -> String {
        let components = text.components(separatedBy: .whitespacesAndNewlines)
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
