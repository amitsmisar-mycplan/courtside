import UIKit

/// The only thing that turns auto-lock off. Screens that need the phone to stay awake each hold it
/// under their own name, and auto-lock comes back when the last one lets go, so one screen closing
/// can't switch it back on under another (a sheet over the recording screen, say).
@MainActor
final class ScreenAwake {
    enum Holder: String {
        case recording
        case playbackMarking
        case processing
        case slowMoPreview
        case findMoments
    }

    static let shared = ScreenAwake { UIApplication.shared.isIdleTimerDisabled = $0 }

    private var holders: Set<Holder> = []
    private let apply: (Bool) -> Void

    /// `apply` sets the system's idle timer; tests pass a fake.
    init(apply: @escaping (Bool) -> Void) {
        self.apply = apply
    }

    /// True while anything holds the screen awake.
    var isHeld: Bool { !holders.isEmpty }

    func hold(_ holder: Holder) {
        let wasHeld = isHeld
        holders.insert(holder)
        if !wasHeld { apply(true) }
    }

    func release(_ holder: Holder) {
        guard holders.remove(holder) != nil, !isHeld else { return }
        apply(false)
    }

    /// Holds or releases, for state that flips both ways.
    func set(_ holder: Holder, awake: Bool) {
        if awake { hold(holder) } else { release(holder) }
    }
}
