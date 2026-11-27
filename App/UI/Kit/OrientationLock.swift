// ScreenLingo – App – Orientation (2.7.0: iPad turns freely; iPhone landscape on Translate and Focus mode only)
import SwiftUI
import UIKit

/// Info.plist allows portrait and landscape; this delegate narrows it to portrait everywhere except the screens that
/// ask for landscape. The capture extension is a separate target and is not affected.
final class ScreenLingoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // 2.7.0: an iPad is never locked. Locking it to portrait broke Split View, Stage Manager and windows,
        // and a keyboard case keeps the iPad in landscape.
        if MainActor.assumeIsolated({ OrientationLock.isPad }) { return .all }
        return OrientationLock.mask
    }
}

@MainActor
enum OrientationLock {
    /// Read by the app delegate. Portrait unless a screen that allows landscape is on screen.
    nonisolated(unsafe) static var mask: UIInterfaceOrientationMask = .portrait
    private static var holders = 0
    /// Read once at launch; the idiom never changes while the app runs.
    static let isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad

    static func allowLandscape(_ allow: Bool) {
        holders = max(0, holders + (allow ? 1 : -1))
        guard !isPad else { return }
        let next: UIInterfaceOrientationMask = holders > 0 ? .allButUpsideDown : .portrait
        guard next != mask else { return }
        mask = next
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if next == .portrait {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

/// Lets the attached screen rotate while it is visible.
struct AllowsLandscape: ViewModifier {
    @State private var holding = false
    func body(content: Content) -> some View {
        content
            .onAppear { if !holding { holding = true; OrientationLock.allowLandscape(true) } }
            .onDisappear { if holding { holding = false; OrientationLock.allowLandscape(false) } }
    }
}

/// One readable column on wide screens (iPad, large phones in landscape): at most 640 pt by default, centred (§13.6).
/// 2.7.0: pages with charts or two columns pass a wider limit.
struct ReadableColumn: ViewModifier {
    var maxWidth: CGFloat = 640
    @Environment(\.horizontalSizeClass) private var sizeClass
    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content.frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
