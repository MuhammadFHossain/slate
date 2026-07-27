import Foundation

/// Dev logging to ~/Library/Application Support/Slate/slate.log (and NSLog), so
/// the key-tap path can be traced from outside the app while wiring up grants.
enum Log {
    private static let fileURL: URL? = {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = base.appendingPathComponent("Slate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("slate.log")
    }()

    static func write(_ message: String) {
        NSLog("Slate: %@", message)
        guard let fileURL else { return }
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
