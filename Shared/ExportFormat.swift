import Foundation

enum ExportFormat {
    /// RFC 4180 cells; neutralize spreadsheet formulas when a CSV is opened in a spreadsheet app.
    static func csvCell(_ value: String) -> String {
        let risky = value.drop(while: { $0 == " " || $0 == "\t" }).first.map { "=+-@".contains($0) } ?? false
        let safe = risky ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n")
    }
    static func normalizedArea(_ lower: Double, _ upper: Double) -> ClosedRange<Double> {
        let lo = min(0.9, max(0, min(lower, upper)))
        let hi = min(1, max(lo + 0.1, max(lower, upper)))
        return lo...hi
    }
}
