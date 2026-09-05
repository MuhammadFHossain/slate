import AppKit
import Foundation
import SwiftUI

/// The quick picker: Command with the talk key opens a short list of recent
/// dictations over whatever app is in front, and Return puts the chosen one
/// at the cursor. For the thing an app just swallowed, or the same sentence
/// needed in a second place: the whole errand is the combo and Return.
///
/// Keys are read from the event tap rather than by making this panel the key
/// window. Slate is a menu-bar accessory, so taking key status would either
/// activate the app — moving focus out of the text field the words are headed
/// for — or quietly fail to receive anything. The tap already owns Escape for
/// the same reason, and it is the one input path that works the same everywhere.
struct PickerRow: Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    let appName: String?

    var blurb: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 56 else { return flat }
        let cut = flat.prefix(56)
        if let space = cut.lastIndex(of: " "), space > cut.startIndex {
            return cut[cut.startIndex..<space] + "…"
        }
        return cut + "…"
    }

    var words: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

/// Whether the picker is on screen, readable from the event tap's thread.
enum PickerState {
    private static let lock = NSLock()
    private static var open = false

    static var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return open }
        set { lock.lock(); open = newValue; lock.unlock() }
    }
}

@MainActor
final class QuickPicker: ObservableObject {
    static let shared = QuickPicker()

    /// Rows on screen at once. Small on purpose: read at a glance, the rest a
    /// scroll away.
    static let visibleRows = 4
    /// A dictation shorter than this never reaches the picker: "Yes." and
    /// "Okay, thanks." have no second use.
    static let minimumWords = 5
    /// How far back the picker reaches.
    static let limit = 20

    @Published private(set) var isOpen = false
    @Published private(set) var selection = 0
    /// Snapshot taken when the panel opens, so a dictation that lands while
    /// it is up cannot renumber the list under the arrow keys.
    @Published private(set) var rows: [PickerRow] = []

    private var panel: FloatingPanel?
    private var clickMonitor: Any?
    private var lastSize = CGSize(width: 460, height: 120)

    func toggle() {
        if isOpen { close() } else { open() }
    }

    static func build(from entries: [DictationEntry]) -> [PickerRow] {
        entries
            .filter { $0.text.split(whereSeparator: { $0.isWhitespace }).count >= minimumWords }
            .prefix(limit)
            .map { PickerRow(id: $0.id, text: $0.text, date: $0.date, appName: $0.appName) }
    }

    func open() {
        // Never over a live turn: the island is using that spot.
        guard DictationController.shared.phase == .idle else { return }
        rows = Self.build(from: DictationHistory.shared.entries)
        selection = 0
        isOpen = true
        PickerState.isOpen = true
        if panel == nil { build() }
        panel?.layoutTopCenter(contentSize: lastSize)
        panel?.orderFrontRegardless()
        // A click anywhere else means the user has moved on.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { _ in
                DispatchQueue.main.async { QuickPicker.shared.close() }
            }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        PickerState.isOpen = false
        panel?.orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    /// Arrow keys, Return and Escape while the panel is open. True when the
    /// key was consumed and must not reach the app underneath — Return above
    /// all, or choosing a row would also send the message being written.
    @discardableResult
    func handleKey(_ keyCode: Int64) -> Bool {
        guard isOpen else { return false }
        switch keyCode {
        case 126: move(by: -1); return true      // up
        case 125: move(by: 1); return true       // down
        case 36, 76: placeSelected(); return true // return, keypad enter
        case 53: close(); return true            // escape
        default:
            // Anything else means the user went back to typing. Get out of
            // the way, but let the keystroke through: it belongs to them.
            close()
            return false
        }
    }

    func choose(_ row: PickerRow) {
        guard let index = rows.firstIndex(of: row) else { return }
        selection = index
        placeSelected()
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    private func placeSelected() {
        guard rows.indices.contains(selection) else { close(); return }
        let row = rows[selection]
        // Closed BEFORE inserting: the paste is a synthetic keystroke aimed at
        // whatever is frontmost.
        close()
        Task {
            switch await TextInserter.insert(row.text) {
            case .placed: SoundCue.play(.placed)
            case .copied: SoundCue.play(.copied)
            }
        }
    }

    private func build() {
        let content = QuickPickerView(onResize: { [weak self] size in
            guard let self else { return }
            self.lastSize = size
            self.panel?.layoutTopCenter(contentSize: size)
        })
        .environmentObject(self)
        panel = FloatingPanel(content: AnyView(content), size: NSSize(width: 460, height: 120), anchored: true)
    }
}

/// The list: a glass card under the menu bar, four rows tall, the rest a
/// scroll away. Same surface as the welcome card and History.
struct QuickPickerView: View {
    @EnvironmentObject var picker: QuickPicker
    var onResize: (CGSize) -> Void

    private static let rowHeight: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if picker.rows.isEmpty {
                empty
            } else {
                list
                footer
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: 460, alignment: .leading)
        .glassCard(radius: 18)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onResize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in onResize(size) }
            }
        )
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing to paste yet")
                .font(Brand.ui(14, weight: .semibold))
                .foregroundStyle(Brand.ink)
            Text("Dictate a few sentences; the latest ones show up here.")
                .font(Brand.ui(12, weight: .regular))
                .foregroundStyle(Brand.inkSoft)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: index == picker.selection)
                            .id(row.id)
                            .onTapGesture { picker.choose(row) }
                    }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(min(QuickPicker.visibleRows, max(picker.rows.count, 1))))
            .onChange(of: picker.selection) { _, index in
                guard picker.rows.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(picker.rows[index].id, anchor: .center)
                }
            }
        }
    }

    private func rowView(_ row: PickerRow, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(selected ? Brand.emerald : Color.clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.blurb)
                    .font(Brand.body(14))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Text(Self.caption(for: row))
                    .font(Brand.ui(11, weight: .regular))
                    .foregroundStyle(Brand.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Brand.emerald.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Brand.emerald.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "move")
            hint("return", "paste")
            hint("esc", "close")
            Spacer(minLength: 0)
            Text("\(min(QuickPicker.visibleRows, picker.rows.count)) of \(picker.rows.count)")
                .font(Brand.ui(11, weight: .regular))
                .foregroundStyle(Brand.inkSoft)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(Brand.ui(10, weight: .semibold))
                .foregroundStyle(Brand.ink.opacity(0.8))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Brand.ink.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Brand.emerald.opacity(0.35), lineWidth: 0.5)
                )
            Text(what)
                .font(Brand.ui(11, weight: .regular))
                .foregroundStyle(Brand.inkSoft)
        }
    }

    /// A dictation names the app it went to; that is how somebody remembers
    /// it ("the thing I wrote in Slack").
    static func caption(for row: PickerRow) -> String {
        var parts: [String] = []
        if let app = row.appName, !app.isEmpty { parts.append(app) }
        parts.append(when(row.date))
        parts.append("\(row.words) words")
        return parts.joined(separator: " · ")
    }

    static func when(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) hr ago" }
        if seconds < 172_800 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = seconds < 604_800 ? "EEEE" : "d MMM"
        return formatter.string(from: date)
    }
}
