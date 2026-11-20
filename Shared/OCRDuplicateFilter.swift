import Foundation

/// 2.5.2: iOS 27's accurate text reader can return the same text twice: once as the whole line and again as
/// separate pieces inside it (reported on Apple's developer forums, thread 851862; the revision number did not
/// change). A caption then looks like more lines than it has: the pixel check gives up above its line limit, a
/// second OCR read is needed, and the duplicated words can reach the translation. This drops a line only when a
/// wider line on the same row covers it and already contains its text. Lines on other rows are never touched.
enum OCRDuplicateFilter {
    static func filter(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count > 1 else { return lines }
        var keep = [Bool](repeating: true, count: lines.count)
        for i in lines.indices {
            for j in lines.indices where j != i && keep[j] {
                if covers(lines[j], lines[i], preferLater: j > i) { keep[i] = false; break }
            }
        }
        return lines.indices.filter { keep[$0] }.map { lines[$0] }
    }

    /// True when `outer` sits on the same row as `inner`, spans it horizontally and contains its text.
    /// For two identical lines only the earlier one is kept (`preferLater` breaks the tie).
    static func covers(_ outer: OCRLine, _ inner: OCRLine, preferLater: Bool) -> Bool {
        let outerWidth = outer.w ?? 0, innerWidth = inner.w ?? 0
        guard outerWidth > 0, innerWidth > 0, outer.h > 0, inner.h > 0 else { return false }
        guard abs(outer.y - inner.y) <= max(outer.h, inner.h) * 0.5 else { return false }
        let slack = 0.01
        guard inner.x - innerWidth / 2 >= outer.x - outerWidth / 2 - slack,
              inner.x + innerWidth / 2 <= outer.x + outerWidth / 2 + slack else { return false }
        let a = normalized(outer.t), b = normalized(inner.t)
        guard !b.isEmpty, a.contains(b) else { return false }
        if a == b && abs(outerWidth - innerWidth) < slack { return !preferLater }
        return outerWidth >= innerWidth
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
