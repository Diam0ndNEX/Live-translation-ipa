import Foundation

// ⚠️ Replace "com.example" everywhere (here + project.yml) with your own prefix.
enum Shared {
    static let appGroup = "group.com.example.screentranslator"
    static let extensionBundleID = "com.example.screentranslator.broadcast"
    static let notifyName = "com.example.screentranslator.newText"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("latest.json")
    }
}

struct OCRPayload: Codable {
    var text: String
    var stamp: Double
}
