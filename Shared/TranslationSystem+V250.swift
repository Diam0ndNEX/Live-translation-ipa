import Foundation

/// 2.5.0: fixed names for the new Diagnostics numbers. Only these names can be recorded, stored and exported, so
/// no caption, OCR or translated text can reach a report through them.
enum V250Names {
    /// Whole-session counts.
    static let counters = [
        "captureStartWarmups", "quietRewarms", "trustedBandReads",
        "headStartPrePasses", "headStartSent", "headStartConfirmed", "headStartMissed"
    ] + extraReadCounters
    /// Why a confirmation needed another OCR read (item C). The order is the order of `Packet.extraReadReasons`.
    static let extraReadCounters = [
        "extraReadPixelRejected", "extraReadNotArmedLines", "extraReadNotArmedInk", "extraReadNotArmedFrame",
        "extraReadDwell", "extraReadMoreReads", "extraReadPixelOff", "extraReadOther"
    ]
    static let extraReadLabels = [
        "pixels changed", "more than 4 lines", "too little ink", "frame not readable",
        "waited for the dwell", "more reads required", "pixel check off", "other"
    ]
    /// Timing samples in milliseconds.
    static let metrics = [
        "captureStartWarmupMs", "quietRewarmMs", "headStartPrePassMs", "lowLatencyWarmupMs"
    ] + ModelLengthBucket.allCases.map(\.metric)
}

/// Item C: the cause of an extra OCR read of an unconfirmed caption, as an index into `V250Names.extraReadCounters`.
enum ExtraReadCause: Int {
    case pixelRejected = 0, notArmedLines, notArmedInk, notArmedFrame, dwell, moreReads, pixelOff, other
}

/// Item D: model call durations grouped by how much text the call translated. Characters are counted, never kept.
enum ModelLengthBucket: String, CaseIterable {
    case to20 = "1to20", to40 = "21to40", to80 = "41to80", to160 = "81to160", over160 = "161Plus"
    var metric: String { "modelLen" + rawValue + "Ms" }
    var label: String {
        switch self {
        case .to20: return "1-20"
        case .to40: return "21-40"
        case .to80: return "41-80"
        case .to160: return "81-160"
        case .over160: return "161+"
        }
    }
    static func bucket(characters: Int) -> ModelLengthBucket {
        switch characters {
        case ...20: return .to20
        case 21...40: return .to40
        case 41...80: return .to80
        case 81...160: return .to160
        default: return .over160
        }
    }
}

/// Item F: decides whether Legacy may start its translation from the fast first OCR pass.
///
/// A head start is only worth it when the text of the fast pass is the text that gets confirmed. Otherwise the
/// Apple Default call it started is wasted and is still running when the real caption is confirmed (the overlap
/// the 2.4.0 audit found). So the extension keeps score: every fast pass is later marked right (the confirmed
/// caption had exactly that text) or wrong (different text confirmed, or the text was replaced before it was
/// confirmed). The head start is used only while at least `requiredShare` of the last `window` fast passes were
/// right. While they are not, the fast pass itself is run only now and then, so its cost is not paid for nothing.
struct HeadStartGovernor {
    static let window = 12
    static let minimumSamples = 6
    static let requiredShare = 0.8
    /// With too few right answers, one fast pass in this many reads keeps the score current.
    static let probeEvery = 6

    private(set) var outcomes: [Bool] = []
    private var opportunities = 0

    var samples: Int { outcomes.count }
    var share: Double {
        outcomes.isEmpty ? 0 : Double(outcomes.filter { $0 }.count) / Double(outcomes.count)
    }
    /// True when a fast-pass text may be sent to start the translation.
    var maySend: Bool { outcomes.count >= Self.minimumSamples && share >= Self.requiredShare }

    /// Whether to run the fast pass on this read at all.
    mutating func shouldRunPrePass() -> Bool {
        opportunities &+= 1
        if outcomes.count < Self.minimumSamples || maySend { return true }
        return opportunities % Self.probeEvery == 0
    }

    mutating func record(right: Bool) {
        outcomes.append(right)
        if outcomes.count > Self.window { outcomes.removeFirst(outcomes.count - Self.window) }
    }
}
