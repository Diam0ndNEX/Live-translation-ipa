// ScreenLingo – App – Feedback: haptics, one toast/banner queue (2.0.0 build 88)
import SwiftUI
import UIKit

enum Feedback {
    /// Respects the existing Interface → haptics switch ("uiHaptics", default on).
    static func tap() {
        guard (UserDefaults.standard.object(forKey: "uiHaptics") as? Bool) ?? true else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func success() {
        guard (UserDefaults.standard.object(forKey: "uiHaptics") as? Bool) ?? true else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var severity: Severity = .info
    var actionTitle: String?
    var action: (() -> Void)?
    static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
}

/// Queue of short messages. One is shown at a time; each stays 3 s (6 s when it has an action).
@MainActor
final class FeedbackCenter: ObservableObject {
    @Published private(set) var current: Notice?
    private var queue: [Notice] = []
    private var timer: Task<Void, Never>?

    func show(_ text: String, severity: Severity = .info, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        guard !text.isEmpty else { return }
        if current?.text == text || queue.contains(where: { $0.text == text }) { return }
        queue.append(Notice(text: text, severity: severity, actionTitle: actionTitle, action: action))
        advanceIfIdle()
    }
    func dismiss() { timer?.cancel(); current = nil; advanceIfIdle() }

    private func advanceIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.action == nil ? 3 : 6))
            guard !Task.isCancelled else { return }
            self?.current = nil
            try? await Task.sleep(for: .milliseconds(250))
            self?.advanceIfIdle()
        }
    }
}

struct NoticeHost: View {
    @ObservedObject var center: FeedbackCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let n = center.current {
                Banner(text: n.text, severity: n.severity, actionTitle: n.actionTitle, action: n.action)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                    .padding(.horizontal, Space.l).padding(.top, Space.s)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .onTapGesture { center.dismiss() }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: Motion.quick) : .spring(response: 0.35, dampingFraction: 0.85), value: center.current)
        .allowsHitTesting(center.current != nil)
    }
}
