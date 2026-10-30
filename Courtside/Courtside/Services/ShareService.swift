import UIKit

/// Presents the system share sheet for a file, from whatever screen is on top.
@MainActor
enum ShareService {
    /// `completion` runs when the sheet closes, whether or not anything was shared.
    static func share(_ url: URL, completion: (() -> Void)? = nil) {
        guard let presenter = topViewController() else {
            completion?()
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in completion?() }
        // iPad-style popover anchor; harmless on iPhone.
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY, width: 0, height: 0)
        presenter.present(sheet, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
