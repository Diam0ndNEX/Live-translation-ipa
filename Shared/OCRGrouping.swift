import Foundation

/// Geometry rules shared by live OCR and regression checks.
enum OCRGrouping {
    static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let byY = lines.sorted { $0.y > $1.y }
        var rows: [[OCRLine]] = []
        for l in byY {
            if let first = rows.last?.first, abs(first.y - l.y) < 0.4 * min(first.h, l.h) {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.flatMap { $0.sorted { $0.x < $1.x } }
    }

    /// Clusters lines that belong together (similar size, stacked closely, overlapping horizontally).
    static func makeBlocks(_ lines: [OCRLine], movie: Bool) -> [[OCRLine]] {
        // Use the same canonical row-based ordering everywhere. Sorting raw OCR
        // observations independently here used to disagree with readingOrder() when
        // several boxes occupied one visual line.
        let ordered = readingOrder(lines)

        var blocks: [[OCRLine]] = []
        for line in ordered {
            let lineWidth = max(line.w ?? 0.2, 0.001)
            var bestIndex: Int?
            var bestScore = -Double.infinity

            for index in blocks.indices {
                guard let previous = blocks[index].last else { continue }
                // A line can only attach to the immediately preceding line of a block.
                // Do not let a distant line jump across another speech bubble.
                let previousWidth = max(previous.w ?? 0.2, 0.001)
                let overlap = min(line.x + lineWidth / 2, previous.x + previousWidth / 2)
                    - max(line.x - lineWidth / 2, previous.x - previousWidth / 2)
                let verticalGap = previous.y - line.y
                let lineHeight = max(previous.h, line.h, 0.001)
                let sizeRatio = min(previous.h, line.h) / lineHeight
                // Compare empty space between box edges, not just center distance.
                // Tall OCR boxes can otherwise bridge separate dialogue bubbles.
                let edgeGap = verticalGap - (previous.h + line.h) / 2

                // Vision y increases upward. Since input is top-to-bottom, the next
                // line must be below the previous line and within a plausible line gap.
                let centerDistance = abs(line.x - previous.x)
                let overlapRatio = overlap / max(0.001, min(lineWidth, previousWidth))
                let horizontalGap = max(
                    0,
                    max(line.x - lineWidth / 2, previous.x - previousWidth / 2)
                        - min(line.x + lineWidth / 2, previous.x + previousWidth / 2)
                )
                let stacked = verticalGap > 0.20 * lineHeight
                    && edgeGap < 0.75 * lineHeight
                    && edgeGap > -0.35 * lineHeight
                    && (overlapRatio > 0.35 || centerDistance < 0.09)
                    // Large horizontal spans often indicate separate speech bubbles
                    // or an OCR line from the floating PiP overlay. Do not bridge them
                    // merely because their text boxes overlap a little.
                    && !(lineWidth > 0.62 && previousWidth > 0.62 && centerDistance > 0.035)
                // Movie subtitles can be returned as multiple side-by-side OCR boxes
                // on one visual row. Claude's working implementation joined these
                // when their box edges were close; keeping them separate lets Movie
                // mode rank a fragment and discard the rest of the actual sentence.
                // Keep the stricter vertical-only rule for comic/game bubbles, where
                // adjacent same-row boxes may belong to different speakers.
                // Vision can split one long subtitle into adjacent boxes whose
                // vertical centers differ slightly (for example, a long left box and
                // a short final-word box on the right). Compare box-edge spacing and
                // the smaller box height, rather than requiring nearly identical
                // center y values; otherwise the last words become a separate block.
                let verticalOverlap = (previous.h + line.h) / 2 - abs(verticalGap)
                let sameMovieRow = movie
                    && verticalOverlap >= min(previous.h, line.h) * 0.45
                    && horizontalGap < 0.06
                guard sizeRatio > 0.45, (stacked || sameMovieRow) else { continue }

                let score = (overlap / min(lineWidth, previousWidth))
                    - abs(edgeGap) / lineHeight * 0.15
                    - abs(line.x - previous.x) * 0.2
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }

            if let bestIndex {
                blocks[bestIndex].append(line)
            } else {
                blocks.append([line])
            }
        }

        // Canonicalize each block's line order after grouping, then order regions
        // top-to-bottom. For regions on the same row, read left-to-right (or RTL
        // in the later mode-specific display ordering).
        return blocks.map { readingOrder($0) }.sorted {
            let ay = $0.map(\.y).max() ?? 0
            let by = $1.map(\.y).max() ?? 0
            if ay != by { return ay > by }
            return ($0.map(\.x).min() ?? 0) < ($1.map(\.x).min() ?? 0)
        }
    }
}
