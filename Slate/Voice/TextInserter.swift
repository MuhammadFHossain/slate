import AppKit
import ApplicationServices
import Foundation

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

        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
