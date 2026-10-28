import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlideKit

/// Small dark settings window, centred on screen (never at an edge).
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Glide Settings"
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var snapshot = false

    var body: some View {
        Form {
            Section("Scrolling") {
                Toggle("Trackpad simulation", isOn: $model.settings.trackpadSimulation)
                    .help("Rubber-band at edges, inertia and swipe gestures in apps")
                modifierRow("⌘ Command", \.command)
                modifierRow("⌥ Option", \.option)
                modifierRow("⇧ Shift", \.shift)
                modifierRow("⌃ Control", \.control)
            }
            Section {
                Toggle("Button remaps", isOn: $model.settings.remapsEnabled)
                ForEach(Array(model.settings.remaps.enumerated()), id: \.offset) { i, r in
                    // Bounds-checked binding + deferred delete: removing a row never indexes past the end.
                    RemapRow(remap: Binding(
                        get: { i < model.settings.remaps.count ? model.settings.remaps[i] : r },
                        set: { if i < model.settings.remaps.count { model.settings.remaps[i] = $0 } })) {
                        DispatchQueue.main.async { if i < model.settings.remaps.count { model.settings.remaps.remove(at: i) } }
                    }
                    .disabled(!model.settings.remapsEnabled)
                }
                Button {
                    model.settings.remaps.append(ButtonRemap(button: .button4, trigger: .click, action: .back))
                    model.settings.remapsEnabled = true
                } label: { Label("Add remap", systemImage: "plus").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
            } header: { Text("Buttons") }
            Section("Gestures") {
                Picker("Hold + drag → Spaces & Mission Control", selection: $model.settings.dragGestureButton) {
                    Text("Off").tag(MouseButton?.none)
                    ForEach(MouseButton.allCases, id: \.self) { Text($0.title).tag(MouseButton?.some($0)) }
                }
                Picker("Hold + scroll", selection: $model.settings.scrollGestureButton) {
                    Text("Off").tag(MouseButton?.none)
                    ForEach(MouseButton.allCases, id: \.self) { Text($0.title).tag(MouseButton?.some($0)) }
                }
                if model.settings.scrollGestureButton != nil {
                    Picker("Scroll does", selection: $model.settings.scrollGestureMode) {
                        ForEach(ScrollGestureMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                ForEach(model.settings.exceptions, id: \.bundleID) { ex in
                    HStack {
                        Text(ex.name).font(.system(size: 12))
                        Text(ex.bundleID).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.settings.exceptions.removeAll { $0.bundleID == ex.bundleID } } label: {
                            Image(systemName: "minus.circle").font(.system(size: 11))
                        }.buttonStyle(.borderless)
                    }
                }
                Menu {
                    ForEach(runningApps(), id: \.0) { app in
                        Button(app.1) { addException(id: app.0, name: app.1) }
                    }
                    Divider()
                    Button("Choose App…") { chooseApp() }
                } label: { Label("Add app", systemImage: "plus").font(.system(size: 11)) }
                    .menuStyle(.borderlessButton).fixedSize()
            } header: { Text("Smoothing off in these apps") }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
                if let note = model.loginItemNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if model.trusted {
                        Text("Allowed").foregroundStyle(.secondary)
                    } else {
                        Button("Allow…", action: model.openAccessibilitySettings).controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(width: 470, height: 600)
    }

    func modifierRow(_ title: String, _ key: WritableKeyPath<ScrollModifiers, ScrollModifierAction>) -> some View {
        Picker(title, selection: Binding(
            get: { model.settings.modifiers[keyPath: key] },
            set: { newValue in
                var m = model.settings.modifiers
                // A behaviour belongs to one modifier at a time (MMF does the same).
                if newValue != .none {
                    for k in [\ScrollModifiers.command, \.option, \.shift, \.control] where m[keyPath: k] == newValue { m[keyPath: k] = .none }
                }
                m[keyPath: key] = newValue
                model.settings.modifiers = m
            })) {
            ForEach(ScrollModifierAction.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    func runningApps() -> [(String, String)] {
        let existing = Set(model.settings.exceptions.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !existing.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    func addException(id: String, name: String) {
        guard !model.settings.exceptions.contains(where: { $0.bundleID == id }) else { return }
        model.settings.exceptions.append(AppException(bundleID: id, name: name))
    }

    func chooseApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url, let b = Bundle(url: url), let id = b.bundleIdentifier else { return }
        let name = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        addException(id: id, name: name)
    }
}

struct RemapRow: View {
    @Binding var remap: ButtonRemap
    var onDelete: () -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $remap.button) {
                ForEach(MouseButton.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().fixedSize()
            Picker("", selection: $remap.trigger) {
                ForEach(ButtonTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().fixedSize()
            Picker("", selection: actionBinding) {
                ForEach(ButtonAction.menuCases, id: \.self) { Text($0.title).tag($0) }
                Divider()
                if case .shortcut = remap.action { Text(remap.action.title).tag(remap.action) }
                Text(recording ? "Press keys…" : "Keyboard Shortcut…").tag(ButtonAction.shortcut(KeyShortcut(keyCode: UInt16.max, modifiers: 0)))
            }.labelsHidden()
            Button(action: onDelete) { Image(systemName: "minus.circle").font(.system(size: 11)) }.buttonStyle(.borderless)
        }
        .onDisappear { stopRecording() }
    }

    var actionBinding: Binding<ButtonAction> {
        Binding(get: { recording ? .shortcut(KeyShortcut(keyCode: UInt16.max, modifiers: 0)) : remap.action },
                set: { v in
                    if case .shortcut(let s) = v, s.keyCode == UInt16.max { startRecording() } else { remap.action = v }
                })
    }

    func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = UInt64(e.modifierFlags.intersection([.command, .option, .shift, .control]).rawValue)
            // NSEvent.ModifierFlags and CGEventFlags share these bit positions.
            remap.action = .shortcut(KeyShortcut(keyCode: e.keyCode, modifiers: mods))
            stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}
