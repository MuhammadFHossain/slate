import Foundation

/// The small error type the audio + speech engines throw. Named from Blue,
/// where these files originated; kept so the carried-over engines compile
/// unchanged.
struct BlueError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
