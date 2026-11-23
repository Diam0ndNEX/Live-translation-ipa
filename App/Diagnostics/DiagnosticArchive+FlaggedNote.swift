import Foundation

/// 2.6.0: one caption that the app flagged by itself (see CaptionSignals and FlaggedCaptionStore). It lives in this
/// file because the report writer needs the type and the archive test programs compile only DiagnosticArchive parts.
struct FlaggedCaptionNote: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var flags: [String]
    var original: String
    var translated: String
    /// The three captions shown before this one, oldest first (original, translation).
    var previous: [[String]]
    var version: String
}
