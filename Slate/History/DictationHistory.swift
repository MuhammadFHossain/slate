import Foundation

/// One thing you said, exactly as Slate placed it (or kept it).
struct DictationEntry: Identifiable, Codable, Equatable {
    enum Outcome: String, Codable {
        /// Typed into an app.
        case placed
        /// Left on the clipboard because nothing was there to type into.
        case copied
        /// Cancelled or failed mid-way; kept here so nothing is ever lost.
        case recovered
    }

    let id: UUID
    let date: Date
    let text: String
    let outcome: Outcome
    let appName: String?

    /// The first line, whitespace collapsed, short enough for a menu.
    var preview: String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let collapsed = firstLine.split(separator: " ").joined(separator: " ")
        if collapsed.count <= 64 { return collapsed }
        return String(collapsed.prefix(63)).trimmingCharacters(in: .whitespaces) + "…"
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Everything you have dictated, newest first, on disk in Slate's own folder.
/// Speech never leaves the Mac; neither does this.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()
    static let limit = 500

    @Published private(set) var entries: [DictationEntry] = []

    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Slate", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fileURL = dir?.appendingPathComponent("history.json")
        load()
    }

    @discardableResult
    func add(_ text: String, outcome: DictationEntry.Outcome, appName: String?) -> DictationEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = DictationEntry(id: UUID(), date: Date(), text: trimmed, outcome: outcome, appName: appName)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
        scheduleSave()
        return entry
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    func clear() {
        entries = []
        scheduleSave()
    }

    // MARK: - Disk

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([DictationEntry].self, from: data) {
            entries = loaded.sorted { $0.date > $1.date }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem {
            guard let url else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
