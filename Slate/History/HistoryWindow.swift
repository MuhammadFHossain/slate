import AppKit
import SwiftUI

// MARK: - Window

/// The History window: a glass sheet listing everything you have said,
/// newest first, with one-click copy. Opened from the menu bar.
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = HistoryView().environmentObject(DictationHistory.shared)
            let hosting = NSHostingView(rootView: root)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Slate History"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.backgroundColor = .clear
            w.isOpaque = false
            w.minSize = NSSize(width: 440, height: 380)
            w.contentView = hosting
            w.center()
            w.setFrameAutosaveName("SlateHistoryWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct HistoryView: View {
    @EnvironmentObject private var history: DictationHistory
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [DictationEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 38)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { entry in
                            HistoryRow(entry: entry) {
                                history.remove(entry.id)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
        .alert("Clear history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything Slate has kept will be removed. This cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(Brand.ui(24, weight: .bold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                if !history.entries.isEmpty {
                    Button("Clear all") { confirmClear = true }
                        .buttonStyle(PillButtonStyle(tone: .quiet))
                }
            }
            Text("Everything you've said, newest first. Click Copy to put any of it back on the clipboard. Nothing here leaves this Mac.")
                .font(Brand.ui(12, weight: .regular))
                .foregroundStyle(Brand.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Brand.inkSoft)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(Brand.ui(13, weight: .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: history.entries.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Brand.emerald)
            Text(history.entries.isEmpty ? "Nothing yet" : "No matches")
                .font(Brand.ui(16, weight: .semibold))
                .foregroundStyle(Brand.ink)
            Text(history.entries.isEmpty
                 ? "Hold Right Option and talk. Everything you say shows up here."
                 : "Try a different word.")
                .font(Brand.ui(12, weight: .regular))
                .foregroundStyle(Brand.inkSoft)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

struct HistoryRow: View {
    let entry: DictationEntry
    var onDelete: () -> Void

    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OutcomeBadge(entry: entry)
                Text(entry.date, format: .relative(presentation: .named))
                    .font(Brand.ui(11, weight: .regular))
                    .foregroundStyle(Brand.inkSoft)
                    .help(entry.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                    .foregroundStyle(Brand.inkSoft)
                Text("\(entry.wordCount) words")
                    .font(Brand.ui(11, weight: .regular))
                    .foregroundStyle(Brand.inkSoft)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    TextInserter.copyToClipboard(entry.text)
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        withAnimation(.easeOut(duration: 0.2)) { copied = false }
                    }
                }
                .buttonStyle(PillButtonStyle(tone: copied ? .done : .accent))
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Brand.inkSoft)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Remove from history")
            }

            Text(entry.text)
                .font(Brand.body(13))
                .foregroundStyle(Brand.ink)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !expanded, entry.text.count > 260 || entry.text.contains("\n") {
                Button("Show more") { withAnimation(.easeOut(duration: 0.2)) { expanded = true } }
                    .buttonStyle(.plain)
                    .font(Brand.ui(11, weight: .semibold))
                    .foregroundStyle(Brand.emerald)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
        }
    }
}

struct OutcomeBadge: View {
    let entry: DictationEntry

    private var label: String {
        switch entry.outcome {
        case .placed:
            if let app = entry.appName { return "Placed in \(app)" }
            return "Placed"
        case .copied: return "Copied to clipboard"
        case .recovered: return "Recovered"
        }
    }

    private var icon: String {
        switch entry.outcome {
        case .placed: return "checkmark.circle.fill"
        case .copied: return "doc.on.clipboard.fill"
        case .recovered: return "lifepreserver.fill"
        }
    }

    private var tint: Color {
        switch entry.outcome {
        case .placed: return Brand.emerald
        case .copied: return Brand.inkSoft
        case .recovered: return Brand.coral
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(Brand.ui(11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - Buttons

/// A small pill button in three tones: the emerald accent, a quiet neutral,
/// and the "done" state after a copy.
struct PillButtonStyle: ButtonStyle {
    enum Tone { case accent, quiet, done }
    var tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.ui(11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(border, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch tone {
        case .accent: return .white
        case .quiet: return Brand.inkSoft
        case .done: return Brand.emerald
        }
    }

    private var background: Color {
        switch tone {
        case .accent: return Brand.emerald
        case .quiet: return Color.primary.opacity(0.06)
        case .done: return Brand.emerald.opacity(0.14)
        }
    }

    private var border: Color {
        switch tone {
        case .accent: return Brand.emerald.opacity(0.6)
        case .quiet: return Color.primary.opacity(0.08)
        case .done: return Brand.emerald.opacity(0.3)
        }
    }
}
