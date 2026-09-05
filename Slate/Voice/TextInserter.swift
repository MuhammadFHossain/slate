import AppKit
import ApplicationServices
import Foundation

/// What the caret's neighborhood looks like in the focused text field, read
/// (never written) through Accessibility. Slate already holds the AX grant
/// for the talk key, so this costs no new permission, and it stays on-device.
struct FocusContext {
    /// The character immediately before the caret, if any.
    var charBefore: Character?
    /// The character immediately after the caret (or after the selection).
    var charAfter: Character?
    /// The last non-whitespace character before the caret ON THIS LINE: what
    /// decides "something is already written here" vs "fresh start". A line
    /// break resets it.
    var lastNonSpaceBefore: Character?

    /// How many characters around the caret are read. Never the whole
    /// document: a huge value would stall the main thread that also services
    /// the event tap.
    private static let windowSize = 24

    /// Read the caret's neighborhood. Nil whenever the app doesn't expose it
    /// (web views and terminals often don't); callers then insert untouched.
    static func fetch() -> FocusContext? {
        let system = AXUIElementCreateSystemWide()
        // A beachballing target app must not hold Slate's main thread: the
        // default AX timeout is ~6 s PER CALL; a bounded one turns a hung app
        // into the nil-context path.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue as AnyObject, to: AXValue.self), .cfRange, &range),
              range.location >= 0
        else { return nil }

        let beforeLength = min(Self.windowSize, range.location)
        guard let before = string(
            for: NSRange(location: range.location - beforeLength, length: beforeLength),
            of: element
        ) else { return nil }
        // Reading past the end fails in most apps; treat that as "at the end".
        let after = string(
            for: NSRange(location: range.location + range.length, length: 1), of: element
        ) ?? ""

        var lastNonSpace: Character?
        for ch in before.reversed() {
            if ch == "\n" { break }
            if !ch.isWhitespace {
                lastNonSpace = ch
                break
            }
        }
        return FocusContext(
            charBefore: before.last,
            charAfter: after.first,
            lastNonSpaceBefore: lastNonSpace
        )
    }

    private static func string(for range: NSRange, of element: AXUIElement) -> String? {
        guard range.length > 0 else { return "" }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &out
        ) == .success else { return nil }
        return out as? String
    }
}

/// Puts the words where you were typing.
///
/// The path is a synthetic ⌘V with the clipboard saved and put back, which
/// works in every app that can paste. Around it: wait until no modifier key
/// is physically down (a tap-to-stop transcript can be ready while Right
/// Option is still held, and ⌘⌥V is not paste), check that something that can
/// take text has focus, and only restore the clipboard if nobody else wrote
/// to it in the meantime.
@MainActor
enum TextInserter {
    enum Outcome: Equatable {
        /// Pasted into the frontmost app; the clipboard was put back afterwards.
        case placed(app: String)
        /// Nothing was there to type into, so the text is on the clipboard.
        case copied
    }

    /// Insert `text` at the cursor of the frontmost app and report how it landed.
    static func insert(_ text: String) async -> Outcome {
        await waitForModifiersUp(timeout: 2.0)

        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "the app"
        let isSlate = app?.bundleIdentifier == Bundle.main.bundleIdentifier
        guard !isSlate, focusCanTakeText() else {
            copyToClipboard(text)
            return .copied
        }

        // What is already written where the words are going: if the caret
        // follows text on its line, the words start a new paragraph rather
        // than running into it (or, with that off, join it with a space and
        // the right case).
        let fitted = fitted(text, to: FocusContext.fetch())

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(fitted, forType: .string)
        let ourChange = pasteboard.changeCount

        postCommandV()

        // Give the app a beat to read the pasteboard (Electron apps are slow
        // to), then put back what was there, unless something else has
        // written to the clipboard since, which is then theirs to keep.
        try? await Task.sleep(nanoseconds: 900_000_000)
        if pasteboard.changeCount == ourChange {
            saved.restore(to: pasteboard)
        }
        return .placed(app: appName)
    }

    /// Only the clipboard, no keystroke: History's Copy, and the fallback.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Fitting text to the caret

    /// Deterministic, like every other cleanup in Slate:
    ///  - something already on the caret's line, and the "new paragraph"
    ///    setting on: the words start a fresh paragraph;
    ///  - otherwise a space is added when the caret sits directly after a
    ///    word or punctuation that needs one, and a first function word is
    ///    lowercased mid-sentence (never a name);
    ///  - a space is appended when the caret sits directly before a word.
    static func fitted(_ text: String, to context: FocusContext?) -> String {
        guard let context, !text.isEmpty else { return text }
        var out = text
        if context.lastNonSpaceBefore != nil, Prefs.bool(Prefs.paragraphAfterText) {
            out = "\n\n" + out
        } else {
            if let last = context.lastNonSpaceBefore, isMidSentence(after: last) {
                out = lowercasedFirstWord(out)
            }
            if let before = context.charBefore, needsSpace(after: before), !startsWithGlue(out) {
                out = " " + out
            }
        }
        if let after = context.charAfter, after.isLetter || after.isNumber, !out.hasSuffix(" ") {
            out += " "
        }
        return out
    }

    /// After a letter, digit, comma, semicolon or colon the sentence is still
    /// going; after . ! ? or an opening bracket it is not.
    private static func isMidSentence(after ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "," || ch == ";" || ch == ":"
    }

    private static func needsSpace(after ch: Character) -> Bool {
        if ch.isWhitespace { return false }
        return !"([{\"'\u{201C}\u{2018}\n/@#-\u{2013}\u{2014}_".contains(ch)
    }

    /// Text that itself begins with punctuation stays glued to the left.
    private static func startsWithGlue(_ text: String) -> Bool {
        guard let first = text.first else { return true }
        return !(first.isLetter || first.isNumber)
    }

    /// Words safe to lowercase when the caret is mid-sentence. Parakeet opens
    /// every transcript with a capital; on one of these the capital is the
    /// model's, not the speaker's. Anything else, names above all, keeps it.
    private static let lowercasableStarters: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "we", "you", "he", "she",
        "they", "it", "this", "that", "these", "those", "my", "your", "our",
        "his", "her", "their", "its", "is", "are", "was", "were", "be", "been",
        "to", "in", "on", "at", "of", "for", "with", "from", "by", "as", "if",
        "when", "then", "there", "here", "what", "which", "how", "why", "who",
        "not", "no", "yes", "do", "does", "did", "can", "could", "will",
        "would", "should", "just", "also", "now", "some", "any", "all", "more",
        "most", "very", "really", "about", "after", "before", "because",
        "let's", "it's", "that's", "there's", "maybe", "please", "thanks", "okay",
    ]

    static func lowercasedFirstWord(_ text: String) -> String {
        let firstWord = text.prefix { !$0.isWhitespace && (!$0.isPunctuation || $0 == "'" || $0 == "\u{2019}") }
        guard let first = firstWord.first, first.isUppercase else { return text }
        let key = firstWord.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard lowercasableStarters.contains(key) else { return text }
        return firstWord.lowercased() + text.dropFirst(firstWord.count)
    }

    // MARK: - Pieces

    private static func waitForModifiersUp(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while HotkeyManager.physicalModifiersDown, Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Roles that are plainly not a place for text. Anything else, including
    /// an unreadable focus, is treated as editable, so the odd app that
    /// reports its editor strangely keeps working the way it always has.
    private static let nonTextRoles: Set<String> = [
        kAXButtonRole, kAXImageRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole,
        kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXPopUpButtonRole,
        kAXDisclosureTriangleRole, kAXIncrementorRole, kAXStaticTextRole, kAXDockItemRole,
        kAXOutlineRole, kAXBrowserRole,
    ]

    private static func focusCanTakeText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard status == .success, let focusedValue else { return true }
        let element = focusedValue as! AXUIElement
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String
        else { return true }
        return !nonTextRoles.contains(role)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV = CGKeyCode(9)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Everything on the pasteboard, every type, so a copied image or file
    /// survives a dictation as well as copied text does.
    private struct PasteboardSnapshot {
        private let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                var copy: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy[type] = data
                    }
                }
                return copy
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored: [NSPasteboardItem] = items.compactMap { entry in
                guard !entry.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (type, data) in entry {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !restored.isEmpty {
                pasteboard.writeObjects(restored)
            }
        }
    }
}
