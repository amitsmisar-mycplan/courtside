import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

enum OrientationLock {
    @MainActor static func set(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            var controller = scene.keyWindow?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}

extension View {
    /// Locks the interface to `mask` while this view is on screen, restoring portrait after.
    func lockedOrientation(_ mask: UIInterfaceOrientationMask) -> some View {
        onAppear { OrientationLock.set(mask) }
            .onDisappear { OrientationLock.set(.portrait) }
    }
}
