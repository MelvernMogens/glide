import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import GlideKit

/// Single source of truth on the main thread: settings + permission state.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: SettingsStore
    @Published var settings: GlideSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            Engine.shared.update(settings: settings)
            if settings.exceptions != oldValue.exceptions { refreshFrontApp() }
        }
    }
    @Published var trusted = AXIsProcessTrusted()
    @Published var engineRunning = false
    @Published var loginItemEnabled = false
    @Published var loginItemNote: String?

    init(defaults: UserDefaults = .standard) {
        store = SettingsStore(defaults: defaults)
        settings = store.load()
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Start the tap if permission allows. Safe to call repeatedly.
    func startEngineIfPossible() {
        trusted = AXIsProcessTrusted()
        guard trusted, !engineRunning else { return }
        engineRunning = Engine.shared.start(settings: settings)
        refreshFrontApp()
    }

    func refreshFrontApp() {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Engine.shared.setFrontAppSmoothingOff(settings.smoothingDisabled(forBundleID: id))
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemNote = nil
        } catch {
            loginItemNote = "Couldn't change: \(error.localizedDescription)"
        }
        // Re-read instead of trusting the toggle.
        let status = SMAppService.mainApp.status
        loginItemEnabled = status == .enabled
        if status == .requiresApproval { loginItemNote = "Approve Glide in System Settings → General → Login Items" }
    }

    func openAccessibilitySettings() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
