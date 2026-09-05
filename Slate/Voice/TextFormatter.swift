import Foundation

/// Turns Parakeet's raw transcript into text you would actually send.
///
/// Parakeet already hears the words, and mostly the punctuation, well. What it
/// hands back is one run-on block, so this layer adds the shape: paragraphs
/// where you paused (the controller splits the audio at pauses and passes each
/// stretch here as its own paragraph), spoken layout and punctuation commands,
/// lists, sentence capitalization, clean spacing, and a proper ending.
enum TextFormatter {
    // MARK: - Public

    /// Compose the text to place. `paragraphs` are the raw transcripts of each
    /// pause-separated stretch, in order. `final` adds the closing period a
    /// finished paragraph deserves; the live transcript passes false so words
    /// do not gain and lose a period while you are mid-sentence.
    static func compose(paragraphs: [String], spaceAfter: Bool, final: Bool = true) -> String {
        var numbered = 0
        var pieces: [String] = []
        for raw in paragraphs {
            let rendered = render(parse(Self.stripFillers(raw), numbered: &numbered))
            let trimmed = tidy(rendered)
            // Empty, or only punctuation a stripped filler left behind (a bare
            // "Uh." becomes "."): nothing worth placing.
            guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if final {
                // A spoken "new paragraph" makes paragraphs inside one stretch;
                // each of them gets its ending.
                let inner = trimmed.components(separatedBy: "\n\n").filter { !$0.isEmpty }
                pieces.append(inner.map(ensureTerminated).joined(separator: "\n\n"))
            } else {
                pieces.append(trimmed)
            }
        }
        var text = pieces.joined(separator: "\n\n")
        if spaceAfter, !text.isEmpty, !text.hasSuffix("\n") {
            text += " "
        }
        return text
    }

    // MARK: - Fillers

    /// Hesitation sounds, never vocabulary: um/uh/erm and friends, in any run
    /// length ASR spells them (um, umm, ummm…). Words people lean on ("like",
    /// "you know") are left alone — cutting those changes meaning. No English
    /// word is a pure um/uh/ah/hm run; "mm" (millimetres), "mhm"/"uh-huh"
    /// (yes), "huh", and "ums"/"uhs" (words about fillers) are kept.
    private static let fillerRuns = "u+m+|u+h+m*|a+h+|h+m+|m{3,}"

    /// Remove hesitation fillers and close the seam they leave. Runs before the
    /// command parse, so "um, scratch that" still reads as a bare command and
    /// "the, um, new products" keeps the determiner the break rules look for.
    static func stripFillers(_ text: String) -> String {
        var out = stripFillerPattern(
            "(?i)(?:,\\s*)?(?<![\\p{L}\\p{N}'\u{2019}@._\\-\"\u{201C}\u{201D}])(?:\(fillerRuns))(?![\\p{L}\\p{N}'\u{2019}@_\\-\"\u{201C}\u{201D}]|\\.[\\p{L}\\p{N}])(?:\\s*,)?\\s*",
            in: text
        )
        // er/erm/err, case-sensitive and guarded: "To err is human", "err on
        // the side of", and the uppercase ER stay words.
        out = stripFillerPattern(
            "(?:,\\s*)?(?<![\\p{L}\\p{N}'\u{2019}@._\\-\"\u{201C}\u{201D}])(?<![Tt]o )e+r+m*(?! on\\b)(?![\\p{L}\\p{N}'\u{2019}@_\\-\"\u{201C}\u{201D}]|\\.[\\p{L}\\p{N}])(?:\\s*,)?\\s*",
            in: out
        )
        // Sentence-initial "Er," / "Erm," is hesitation wearing the model's
        // capital; capitalized forms elsewhere stay words.
        out = stripFillerPattern(
            "(?:^|(?<=[.!?]\\s))E+r+m*(?! on\\b)(?![\\p{L}\\p{N}'\u{2019}@_\\-\"\u{201C}\u{201D}]|\\.[\\p{L}\\p{N}])(?:\\s*,)?\\s*",
            in: out
        )
        return out
    }

    private static func stripFillerPattern(_ pattern: String, in text: String) -> String {
        guard let regex = compiled(pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let matched = ns.substring(with: match.range)
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Keep ONE comma if the filler had one on each side; else drop it
            // whole. Never pad a space onto one already there.
            let leadingComma = matched.hasPrefix(",")
            let trailingComma = matched.dropFirst().contains(",")
            if leadingComma && trailingComma {
                out += ", "
            } else if !out.isEmpty, let last = out.last, !last.isWhitespace {
                out += " "
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()
    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = regex
        return regex
    }

    // MARK: - Spoken commands

    private enum Command {
        case punct(String)
        case open(String)
        case close(String)
        case join(String)
        case newline
        case paragraph
        case bullet
        case number
        case scratch
    }

    /// Spoken commands, matched on the lowercased words with any punctuation
    /// Parakeet attached to them stripped. "Period" is deliberately absent:
    /// Parakeet ends sentences itself, and "period" is too often a real word
    /// (the trial period) to be safe to eat.
    private static let commands: [String: Command] = [
        "comma": .punct(","),
        "question mark": .punct("?"),
        "exclamation mark": .punct("!"),
        "exclamation point": .punct("!"),
        "semicolon": .punct(";"),
        "semi colon": .punct(";"),
        "ellipsis": .punct("…"),
        "dot dot dot": .punct("…"),
        "open quote": .open("\""),
        "open quotes": .open("\""),
        "begin quote": .open("\""),
        "close quote": .close("\""),
        "close quotes": .close("\""),
        "end quote": .close("\""),
        "end quotes": .close("\""),
        "open paren": .open("("),
        "open parenthesis": .open("("),
        "open bracket": .open("["),
        "close paren": .close(")"),
        "close parenthesis": .close(")"),
        "close bracket": .close("]"),
        "hyphen": .join("-"),
        "new line": .newline,
        "newline": .newline,
        "next line": .newline,
        "line break": .newline,
        "new paragraph": .paragraph,
        "next paragraph": .paragraph,
        "paragraph break": .paragraph,
        "bullet point": .bullet,
        "new bullet": .bullet,
        "next bullet": .bullet,
        "new bullet point": .bullet,
        "next bullet point": .bullet,
        "next number": .number,
        "new number": .number,
        "numbered item": .number,
        "scratch that": .scratch,
        "delete that": .scratch,
        "strike that": .scratch,
    ]

    private enum Piece {
        case word(String)
        case punct(String)
        case open(String)
        case close(String)
        case join(String)
        case newline
        case paragraph
        case bullet
        case number(Int)
    }

    /// The command lookup key for a token: lowercased, with Parakeet's own
    /// punctuation stripped from both ends ("Paragraph." -> "paragraph").
    private static func core(_ token: String) -> String {
        token
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .lowercased()
    }

    private static func parse(_ raw: String, numbered: inout Int) -> [Piece] {
        let tokens = raw
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        var pieces: [Piece] = []
        var index = 0
        while index < tokens.count {
            var matched = false
            // Longest command first, so "new bullet point" beats "new bullet".
            for length in stride(from: min(3, tokens.count - index), through: 1, by: -1) {
                let phrase = tokens[index..<(index + length)].map(core).joined(separator: " ")
                guard let command = commands[phrase] else { continue }
                // "It was close. Quote me on that" is not "close quote": a
                // mark inside the phrase means these were separate words.
                if length > 1 {
                    let brokenInside = tokens[index..<(index + length - 1)].contains { token in
                        token.last.map { ".,;:!?".contains($0) } ?? false
                    }
                    if brokenInside { continue }
                }
                switch command {
                case .punct(let mark): pieces.append(.punct(mark))
                case .open(let mark): pieces.append(.open(mark))
                case .close(let mark): pieces.append(.close(mark))
                case .join(let mark): pieces.append(.join(mark))
                case .newline: pieces.append(.newline)
                case .paragraph: pieces.append(.paragraph)
                case .bullet: pieces.append(.bullet)
                case .number:
                    numbered += 1
                    pieces.append(.number(numbered))
                case .scratch: pieces = scratched(pieces)
                }
                index += length
                matched = true
                break
            }
            if !matched {
                pieces.append(.word(tokens[index]))
                index += 1
            }
        }
        return pieces
    }

    /// "Scratch that": drop everything back to the previous sentence end (or
    /// line start). If the last thing said was a finished sentence, that whole
    /// sentence goes.
    private static func scratched(_ pieces: [Piece]) -> [Piece] {
        var result = pieces
        var removedAny = false
        while let last = result.last {
            let endsSentence: Bool
            switch last {
            case .punct(let mark):
                endsSentence = ".!?".contains(mark)
            case .word(let word):
                endsSentence = word.last.map { ".!?".contains($0) } ?? false
            case .paragraph, .newline, .bullet, .number:
                endsSentence = true
            case .open, .close, .join:
                endsSentence = false
            }
            if endsSentence, removedAny { break }
            result.removeLast()
            removedAny = true
        }
        return result
    }

    // MARK: - Rendering

    private static func render(_ pieces: [Piece]) -> String {
        var out = ""
        var suppressSpace = false

        func trimTrailingSpaces() {
            while out.last == " " { out.removeLast() }
        }
        func spaceIfNeeded() {
            guard !out.isEmpty, !suppressSpace, !out.hasSuffix("\n"), out.last != " " else { return }
            out += " "
        }
        func lineStart() {
            trimTrailingSpaces()
            if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        }

        for piece in pieces {
            switch piece {
            case .word(let word):
                spaceIfNeeded()
                out += word
                suppressSpace = false

            case .punct(let mark):
                trimTrailingSpaces()
                // Nothing to attach a mark to yet.
                if out.isEmpty || out.hasSuffix("\n") { continue }
                if let last = out.last {
                    if String(last) == mark { continue }          // "there, comma" -> one comma
                    if ",;:.!?".contains(last) { out.removeLast() } // the spoken mark wins
                }
                out += mark
                suppressSpace = false

            case .open(let mark):
                spaceIfNeeded()
                out += mark
                suppressSpace = true

            case .close(let mark):
                trimTrailingSpaces()
                out += mark
                suppressSpace = false

            case .join(let mark):
                trimTrailingSpaces()
                out += mark
                suppressSpace = true

            case .newline:
                trimTrailingSpaces()
                if !out.isEmpty, !out.hasSuffix("\n\n") { out += "\n" }
                suppressSpace = false

            case .paragraph:
                trimTrailingSpaces()
                while out.hasSuffix("\n") { out.removeLast() }
                if !out.isEmpty { out += "\n\n" }
                suppressSpace = false

            case .bullet:
                lineStart()
                out += "- "
                suppressSpace = true

            case .number(let n):
                lineStart()
                out += "\(n). "
                suppressSpace = true
            }
        }
        return out
    }

    // MARK: - Tidying

    /// Abbreviations whose period does not end a sentence.
    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "dr", "mr", "mrs", "ms", "st", "approx", "dept", "inc", "jr", "sr",
    ]

    /// Spacing, standalone "i", and sentence capitalization over the whole text.
    static func tidy(_ text: String) -> String {
        var s = text
        // Runs of spaces become one; tabs are spaces.
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        // No space before closing punctuation.
        s = s.replacingOccurrences(of: "[ \\t]+([,.;:!?…)\\]])", with: "$1", options: .regularExpression)
        // A comma running into a full stop is just the full stop.
        s = s.replacingOccurrences(of: "[,;:]+([.!?…])", with: "$1", options: .regularExpression)
        // No space after an opening bracket or quote that opens a run.
        s = s.replacingOccurrences(of: "([(\\[])[ \\t]+", with: "$1", options: .regularExpression)
        // A space after a comma, semicolon or colon when a word follows.
        s = s.replacingOccurrences(of: "([,;:])(?=[A-Za-z])", with: "$1 ", options: .regularExpression)
        // A space after a sentence end when the next sentence follows unspaced.
        s = s.replacingOccurrences(of: "(?<=[a-z])([.!?])(?=[A-Z])", with: "$1 ", options: .regularExpression)
        // The pronoun.
        s = s.replacingOccurrences(
            of: "(?<![\\w'’-])i(?=[\\s'’,;:!?…)\\]\"]|\\.(?![A-Za-z])|$)",
            with: "I", options: .regularExpression
        )
        // A list marker with nothing after it (a scratched item, or a trailing
        // "bullet point") is not a line.
        s = s.replacingOccurrences(of: "(?m)^(?:-|\\d+\\.) ?$\\n?", with: "", options: .regularExpression)
        s = capitalizeSentences(s)
        // No trailing spaces on lines.
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uppercase the first letter of the text, of every line, and of every
    /// sentence after . ! ? (skipping the common abbreviations and decimals).
    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var capitalizeNext = true
        var pendingTerminator = false
        var currentWord = ""

        for ch in text {
            if ch == "\n" {
                result.append(ch)
                capitalizeNext = true
                pendingTerminator = false
                currentWord = ""
                continue
            }
            if ch.isLetter {
                if capitalizeNext {
                    result += String(ch).uppercased()
                    capitalizeNext = false
                } else {
                    result.append(ch)
                }
                pendingTerminator = false
                currentWord.append(ch)
                continue
            }
            if ch.isNumber {
                result.append(ch)
                capitalizeNext = false
                pendingTerminator = false
                currentWord.append(ch)
                continue
            }
            result.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let word = currentWord.lowercased()
                let isAbbreviation = ch == "." && abbreviations.contains(word)
                pendingTerminator = !isAbbreviation
                currentWord = ch == "." ? currentWord + "." : ""
            } else if ch.isWhitespace {
                if pendingTerminator {
                    capitalizeNext = true
                    pendingTerminator = false
                }
                currentWord = ""
            } else if ch == "'" || ch == "’" {
                currentWord.append(ch)
            }
            // Other symbols (quotes, brackets, dashes) neither start nor end a
            // word, and a sentence that opens with a quote still capitalizes.
        }
        return result
    }

    /// A finished paragraph ends with a mark. Short fragments (a search term,
    /// a name) and list items are left alone.
    private static func ensureTerminated(_ paragraph: String) -> String {
        guard let last = paragraph.last, last.isLetter || last.isNumber else { return paragraph }
        let lastLine = paragraph.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let isListItem = lastLine.hasPrefix("- ")
            || lastLine.range(of: "^\\d+\\. ", options: .regularExpression) != nil
        guard !isListItem else { return paragraph }
        let words = paragraph.split(separator: " ").count
        guard words >= 4 else { return paragraph }
        return paragraph + "."
    }
}
