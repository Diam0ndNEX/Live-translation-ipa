import UIKit

// 2.8.0 (switch ownWindowCapture, default on). On iPad, ScreenLingo can share the screen with the app being watched
// (Split View, Stage Manager, Slide Over). It used to count as "on screen" in every such state, so the capture skipped
// every frame while its heartbeat kept the link alive: translations stopped with no message (report 2.7.1 build 132:
// nothing after 5.5 min). Now the capture learns where ScreenLingo's window is, keeps reading the rest of the screen,
// and pauses only when ScreenLingo covers most of it. Unverified on a device.
extension TranslatorEngine {
    /// ScreenLingo's window as screen fractions [x, y, width, height] (top left), or nil when unknown or switched off.
    func currentOwnWindow() -> [Double]? {
        guard TranslationHotPathAB.ownWindowCapture else { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return nil }
        let screen = scene.screen.coordinateSpace.bounds
        guard screen.width > 0, screen.height > 0 else { return nil }
        let frame = window.convert(window.bounds, to: scene.screen.coordinateSpace)
        let values = [frame.minX / screen.width, frame.minY / screen.height,
                      frame.width / screen.width, frame.height / screen.height].map { Double(($0 * 100).rounded() / 100) }
        return OwnWindowCapture.valid(values)
    }

    /// Called every tick: tells the capture when the window appeared, moved, resized or went away.
    func refreshOwnWindow() {
        let window = appInterfaceVisible ? currentOwnWindow() : nil
        if window != sentOwnWindow {
            sentOwnWindow = window
            syncConfig()
        }
        guard diag.enabled, captureAlive, appInterfaceVisible, flag("suppressOwnInterface", true) else { return }
        if ownInterfaceBlocksCapture { diag.s.ownWindowPausedSeconds += 1 } else { diag.s.ownWindowSharedSeconds += 1 }
    }

    /// True when ScreenLingo's own screen keeps the capture from reading (the rule before 2.8.0 when the switch is off).
    var ownInterfaceBlocksCapture: Bool {
        appInterfaceVisible && flag("suppressOwnInterface", true) &&
            OwnWindowCapture.pausesAll(visible: true, window: sentOwnWindow, rotated: effectiveRot != 0)
    }

    /// Heartbeat pings carry how long the capture's current OCR read has run. Over 5 s it is stuck: say so once.
    func noteCaptureReadBusy(_ busyMs: Double?) {
        guard let busyMs, busyMs.isFinite, busyMs >= 5000 else {
            if captureReadStuck { captureReadStuck = false }
            return
        }
        if diag.enabled { diag.s.captureReadStuckMaxMs = max(diag.s.captureReadStuckMaxMs, Int(busyMs)) }
        guard !captureReadStuck else { return }
        captureReadStuck = true
        if diag.enabled { diag.s.captureReadStuck += 1 }
        status = "Capture is not reading the screen (stuck for \(Int(busyMs / 1000)) s). Stop and start the broadcast if it does not recover."
    }
}
