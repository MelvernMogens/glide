import AppKit
import GlideKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        _ = Engine.shared.start(settings: SettingsStore().load())
    }
}
