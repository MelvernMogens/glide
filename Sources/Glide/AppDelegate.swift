import AppKit
import GlideKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.shared
    var menu: MenuController!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        menu = MenuController(model: model)
        model.startEngineIfPossible()

        // Permission watcher: cheap check every 2 s, so a grant starts Glide and a revoke shows the
        // one-line warning in the menu. No modal, no notification.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermission() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.refreshFrontApp()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Engine.shared.screensChanged()
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("SwipeScrollDirectionDidChangeNotification"), object: nil, queue: .main) { _ in
            Engine.shared.refreshSystemDirection()
        }

        let args = CommandLine.arguments
        if args.contains("--settings") { SettingsWindow.shared.show(model: model) }
        if args.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.menu.popUpForTesting() }
        }
    }

    private func checkPermission() {
        let now = AXIsProcessTrusted()
        if now != model.trusted { model.trusted = now }
        if now && !model.engineRunning { model.startEngineIfPossible() }
        if model.engineRunning {
            Engine.shared.perform {
                // A revoked grant disables the tap and re-enabling fails: reflect it.
                let ok = Engine.shared.tapIsEnabled || !Engine.shared.settings.enabled
                if !ok { Engine.shared.reenableTapFromMain() }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        let done = DispatchSemaphore(value: 0)
        Engine.shared.perform { Engine.shared.flushAll(); done.signal() }
        _ = done.wait(timeout: .now() + 0.3)
    }
}
