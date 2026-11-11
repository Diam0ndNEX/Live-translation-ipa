// ScreenLingo – App – UI kit: StartButton (2.1.0, spec §13.4.3)
import SwiftUI

/// 88 pt accent circle with the real system broadcast picker inside, so one genuine tap starts capture.
/// Idle: a slow 4 s breathing glow (static with Reduce Motion). Live: a pulsing ring.
/// It is the only filled shape on the idle screen, and the only element allowed a glow.
struct StartButton: View {
    var live: Bool
    var size: CGFloat = 88
    var onTap: () -> Void = {}
    /// 2.5.0: when set, a tap runs this instead of opening the system broadcast sheet (Low Latency without its
    /// language pack asks what to do first). Nil is the normal button.
    var intercept: (() -> Void)? = nil

    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Glow (idle) or ring (live). Decorative only.
            Circle()
                .fill(RadialGradient(colors: [Color.accentColor.opacity(0.45), .clear], center: .center,
                                     startRadius: size * 0.3, endRadius: size * 0.95))
                .frame(width: size * 1.9, height: size * 1.9)
                .scaleEffect(reduceMotion || live ? 1 : (breathe ? 1.08 : 0.92))
                .opacity(live ? 0 : (reduceMotion ? 0.7 : (breathe ? 0.9 : 0.5)))
                .accessibilityHidden(true)
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 3)
                .frame(width: size + 18, height: size + 18)
                .scaleEffect(live && !reduceMotion && breathe ? 1.12 : 1)
                .opacity(live ? (reduceMotion ? 0.8 : (breathe ? 0 : 0.8)) : 0)
                .accessibilityHidden(true)
            Circle()
                .fill(Color.accentColor)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            Image(systemName: live ? "stop.fill" : "play.fill")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .offset(x: live ? 0 : 3)
                .accessibilityHidden(true)
            // The real picker sits on top with its own glyph hidden, so taps reach ReplayKit.
            if let intercept {
                Button(action: intercept) { Color.clear }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .accessibilityLabel("Start capture")
                    .accessibilityHint("Asks about the missing language pack first")
            } else {
                BroadcastPicker(onTap: onTap, hidesGlyph: true)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .accessibilityLabel(live ? "Stop capture" : "Start capture")
                    .accessibilityHint("Opens the system broadcast sheet")
            }
        }
        .frame(width: size * 1.9, height: size * 1.9)
        .onAppear { startAnimating() }
        .onChange(of: reduceMotion) { _, _ in startAnimating() }
    }

    private func startAnimating() {
        guard !reduceMotion else { breathe = false; return }
        breathe = false
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { breathe = true }
    }
}
