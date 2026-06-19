import Foundation

/// Loads custom vocabulary from a folder of `.txt` files.
///
/// File format (one rule per line, `#` for comments, blank lines ignored):
///
/// ```
/// # Terms — canonical spelling, applied via case normalization + fuzzy match
/// PostgreSQL
/// San Francisco
///
/// # Corrections — pattern on the left, replacement on the right
/// Post Grass = PostgreSQL
/// ```
enum VocabularyLoader {
    struct VocabularySet: Sendable {
        let terms: [String]
        let corrections: [String: String]

        var isEmpty: Bool { terms.isEmpty && corrections.isEmpty }
    }

    /// Reads every `.txt` file in `directory` (sorted by name) and merges the rules.
    /// Returns an empty set if the folder is missing or unreadable.
    static func load(from directory: URL) -> VocabularySet {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return VocabularySet(terms: [], corrections: [:])
        }

        var terms: [String] = []
        var corrections: [String: String] = [:]

        let txtFiles = files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in txtFiles {
            guard var content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Strip a leading UTF-8 BOM if present.
            if content.hasPrefix("\u{FEFF}") { content = String(content.dropFirst()) }

            for rawLine in content.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }

                // `pattern = replacement` is a correction; anything else is a term.
                if let eq = line.range(of: "=") {
                    let pattern = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                    let replacement = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !pattern.isEmpty && !replacement.isEmpty {
                        corrections[pattern] = replacement
                    }
                } else {
                    terms.append(line)
                }
            }
        }

        return VocabularySet(terms: Array(Set(terms)), corrections: corrections)
    }
}

/// Applies custom-vocabulary fixes to transcribed text in three passes:
///
/// 1. **Explicit corrections** — `pattern → replacement`, case-insensitive, on word
///    boundaries (so "Post Grass" → "PostgreSQL" but "Post Grasshopper" is untouched).
/// 2. **Case normalization** — known terms are forced to their canonical casing
///    ("postgresql" → "PostgreSQL", "san francisco" → "San Francisco").
/// 3. **Fuzzy match** — capitalized words within a small edit distance of a single-word
///    term are snapped to it ("Postgre" → "PostgreSQL"), only when the match is unambiguous.
///
/// Built once per session from immutable rule data, so it is `Sendable` and cheap to copy
/// into the audio callbacks.
struct VocabularyCorrector: Sendable {
    /// Explicit `pattern → replacement` rules, longest pattern first so the most
    /// specific match wins.
    private let corrections: [(pattern: String, replacement: String)]
    /// lowercased term/replacement → canonical casing.
    private let canonicalByLowercased: [String: String]
    /// Single-word terms eligible for fuzzy matching.
    private let fuzzyTerms: [String]
    /// Largest word count across multi-word canonical entries (1 if none).
    private let maxPhraseLength: Int

    var termCount: Int { canonicalByLowercased.count }
    var correctionCount: Int { corrections.count }

    /// True when there are no rules at all — callers can skip allocating one.
    var isEmpty: Bool { corrections.isEmpty && canonicalByLowercased.isEmpty }

    init(terms: [String], corrections: [String: String]) {
        self.corrections = corrections
            .map { (pattern: $0.key, replacement: $0.value) }
            .sorted { $0.pattern.count > $1.pattern.count }

        var canonical: [String: String] = [:]
        var fuzzy: [String] = []
        var maxPhrase = 1

        func register(_ phrase: String) {
            let words = phrase.split(separator: " ")
            guard !words.isEmpty else { return }
            canonical[phrase.lowercased()] = phrase
            maxPhrase = max(maxPhrase, words.count)
            if words.count == 1 { fuzzy.append(phrase) }
        }

        terms.forEach(register)
        // Correction targets are also canonical spellings worth normalizing toward.
        corrections.values.forEach(register)

        self.canonicalByLowercased = canonical
        self.fuzzyTerms = fuzzy
        self.maxPhraseLength = maxPhrase
    }

    /// Returns `text` with all vocabulary rules applied.
    func apply(_ text: String) -> String {
        guard !isEmpty else { return text }
        var result = applyExplicitCorrections(to: text)
        result = applyCaseNormalization(to: result)
        result = applyFuzzyMatching(to: result)
        return result
    }

    // MARK: - Pass 1: explicit corrections

    private func applyExplicitCorrections(to text: String) -> String {
        guard !corrections.isEmpty else { return text }
        var current = text
        for entry in corrections {
            var searchStart = current.startIndex
            while searchStart < current.endIndex,
                  let range = current.range(of: entry.pattern,
                                            options: .caseInsensitive,
                                            range: searchStart..<current.endIndex) {
                let boundedBefore = range.lowerBound == current.startIndex
                    || !current[current.index(before: range.lowerBound)].isLetterOrDigit
                let boundedAfter = range.upperBound == current.endIndex
                    || !current[range.upperBound].isLetterOrDigit
                guard boundedBefore && boundedAfter else {
                    searchStart = range.upperBound
                    continue
                }
                current.replaceSubrange(range, with: entry.replacement)
                searchStart = current.index(range.lowerBound, offsetBy: entry.replacement.count)
            }
        }
        return current
    }

    // MARK: - Pass 2: case normalization

    private func applyCaseNormalization(to text: String) -> String {
        guard !canonicalByLowercased.isEmpty else { return text }
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        // Try the longest phrases first so "san francisco" wins over "francisco".
        for window in stride(from: maxPhraseLength, through: 1, by: -1) {
            guard tokens.count >= window else { continue }
            var i = 0
            while i + window <= tokens.count {
                let (lead, core, trail) = splitAffixes(tokens[i..<(i + window)])
                if let canonical = canonicalByLowercased[core.lowercased()], canonical != core {
                    let replacement = lead + canonical + trail
                    tokens.replaceSubrange(i..<(i + window),
                                           with: replacement.split(separator: " ").map(String.init))
                    i += max(1, replacement.split(separator: " ").count)
                } else {
                    i += 1
                }
            }
        }
        return tokens.joined(separator: " ")
    }

    /// Splits leading/trailing punctuation off a token window so "postgresql." still matches.
    private func splitAffixes(_ window: ArraySlice<String>) -> (lead: String, core: String, trail: String) {
        let joined = window.joined(separator: " ")
        let lead = String(joined.prefix(while: { $0.isPunctuation }))
        let trailReversed = String(joined.reversed().prefix(while: { $0.isPunctuation }))
        let trail = String(trailReversed.reversed())
        let coreStart = joined.index(joined.startIndex, offsetBy: lead.count)
        let coreEnd = joined.index(joined.endIndex, offsetBy: -trail.count)
        guard coreStart <= coreEnd else { return ("", joined, "") }
        return (lead, String(joined[coreStart..<coreEnd]), trail)
    }

    // MARK: - Pass 3: fuzzy matching

    private func applyFuzzyMatching(to text: String) -> String {
        guard !fuzzyTerms.isEmpty else { return text }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        let corrected = tokens.map { token -> String in
            let stripped = token.trimmingCharacters(in: .punctuationCharacters)
            // Only consider capitalized words of meaningful length that aren't already known.
            guard stripped.count >= 4,
                  let first = stripped.first, first.isUppercase,
                  canonicalByLowercased[stripped.lowercased()] == nil else {
                return token
            }

            // Compare case-insensitively so canonical spellings with mixed casing
            // (e.g. "PostgreSQL") still match lowercase ASR output ("postgres").
            let strippedChars = Array(stripped.lowercased())
            var matches: [String] = []
            for term in fuzzyTerms where term.count >= 4 {
                let threshold = max(1, term.count / 4)
                let distance = Self.levenshtein(strippedChars, Array(term.lowercased()))
                if distance > 0 && distance <= threshold { matches.append(term) }
            }

            // Replace only when exactly one term matches, preserving surrounding punctuation.
            guard matches.count == 1 else { return token }
            let lead = String(token.prefix(while: { $0.isPunctuation }))
            let trail = String(String(token.reversed()).prefix(while: { $0.isPunctuation }).reversed())
            return lead + matches[0] + trail
        }
        return corrected.joined(separator: " ")
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
