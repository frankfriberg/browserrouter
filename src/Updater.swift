import AppKit
import Sparkle

/// Checking for a new version, and getting the release notes in front of someone.
///
/// **An `LSUIElement` app has nowhere to show an update.** It has no Dock icon, it is not
/// in the ⌘-tab list, and a window it orders front arrives behind whatever the user is
/// actually looking at. Sparkle knows this happens and hands the decision over rather than
/// guessing: the two callbacks below are where the app is promoted to an ordinary app for
/// as long as the update session lasts, and put back afterwards.
///
/// That promotion is the whole point of showing the update at all. Silent installs are
/// less trouble and would need none of this; they also mean nobody ever reads what
/// changed.
final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    /// **Promotion is not this class's to do.** Whether the app can go back to being an
    /// accessory depends on whether the rules window is open, which only the app delegate
    /// knows, so both directions are handed in rather than reached for.
    private let promote: () -> Void
    private let demote: () -> Void
    private var controller: SPUStandardUpdaterController?

    init(promote: @escaping () -> Void, demote: @escaping () -> Void) {
        self.promote = promote
        self.demote = demote
        super.init()
        // `startingUpdater: true` begins the scheduled checks; the feed url and the public
        // key come from Info.plist, so there is nothing to configure here that could
        // disagree with what was signed.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    /// The menu item's target. Sparkle's own action, so a check the user asked for reports
    /// "you're up to date" instead of doing nothing visible.
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    // MARK: - Being visible for as long as it takes

    /// **Both the Dock icon and the window arrive here.** Called before Sparkle shows
    /// anything, whether the check was scheduled or asked for, so it is the one place that
    /// can put the app somewhere a window will be seen.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        promote()
    }

    /// The session is over — the update was installed, skipped, or dismissed. Back to an
    /// accessory, unless the rules window is open, which the delegate checks.
    func standardUserDriverWillFinishUpdateSession() {
        demote()
    }

    // MARK: - Handing the process back

    /// **Sparkle relaunches the app with no arguments, and this app's arguments are how it
    /// knows what it is.** Relaunched plainly it would put a rules window on screen that
    /// nobody asked for, right after an update, which reads as the update having gone
    /// wrong. The flag is left here and read once on the next launch.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Setup.relaunchingForUpdate = true
    }
}
