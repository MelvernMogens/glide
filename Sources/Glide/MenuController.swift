import AppKit
import SwiftUI
import GlideKit

/// Menu-bar item + compact dark dropdown.
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let model: AppModel
    private var panelItem = NSMenuItem()
    private var hosting: NSHostingView<MenuPanel>!

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Glide")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            img?.isTemplate = true
            button.image = img
            button.toolTip = "Glide"
        }
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.delegate = self
        menu.autoenablesItems = false

        hosting = NSHostingView(rootView: MenuPanel(model: model, openSettings: { [weak self] in self?.openSettings() }))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame.size = hosting.fittingSize
        panelItem.view = hosting
        menu.addItem(panelItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Glide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.trusted = AXIsProcessTrusted()
        hosting.layoutSubtreeIfNeeded()
        hosting.frame.size = hosting.fittingSize
    }

    @objc private func openSettingsAction() { openSettings() }

    func openSettings() {
        menu.cancelTracking()
        SettingsWindow.shared.show(model: model)
    }

    /// For automated verification: pop the menu open under the icon.
    func popUpForTesting() {
        guard let b = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 5), in: b)
    }

    var statusItemFrame: NSRect { statusItem.button?.window?.frame ?? .zero }
}

/// The control block at the top of the dropdown. Small controls, no big buttons.
struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    var snapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Glide").font(.system(size: 13, weight: .semibold))
                Spacer()
                toggle(isOn: $model.settings.enabled)
            }
            if !model.trusted {
                Button(action: model.openAccessibilitySettings) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Allow Glide in Accessibility to start").underline()
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            row("Smoothness") {
                segmented(Smoothness.allCases, selection: $model.settings.smoothness) { s in
                    s == .medium ? "Med" : s.title
                }
            }
            row("Speed") {
                segmented(ScrollSpeed.allCases, selection: $model.settings.speed) { s in s == .medium ? "Med" : s.title }
            }
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Reverse direction").font(.system(size: 12))
                    Text("Natural, like the trackpad").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                toggle(isOn: $model.settings.reverseDirection)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 270)
        .disabled(false)
    }

    @ViewBuilder func toggle(isOn: Binding<Bool>) -> some View {
        if snapshot {
            Capsule().fill(isOn.wrappedValue ? Color.accentColor : Color.gray.opacity(0.4)).frame(width: 26, height: 15)
        } else {
            // Menus are never the key window, so the system switch draws gray even when on.
            // A tiny custom switch keeps the on-state readable.
            Toggle("", isOn: isOn).toggleStyle(MiniSwitch()).labelsHidden()
        }
    }

    func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 74, alignment: .leading)
            content()
        }
    }

    @ViewBuilder func segmented<T: Hashable>(_ all: [T], selection: Binding<T>, label: @escaping (T) -> String) -> some View {
        if snapshot {
            HStack(spacing: 2) {
                ForEach(all, id: \.self) { v in
                    Text(label(v)).font(.system(size: 10))
                        .frame(maxWidth: .infinity).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(v == selection.wrappedValue ? Color.white.opacity(0.25) : .clear))
                }
            }
            .padding(1).background(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.2)))
        } else {
            Picker("", selection: selection) {
                ForEach(all, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
        }
    }
}

/// 26×15 pt switch that always shows its state (blue = on).
struct MiniSwitch: ToggleStyle {
    func makeBody(configuration c: Configuration) -> some View {
        ZStack(alignment: c.isOn ? .trailing : .leading) {
            Capsule().fill(c.isOn ? Color.accentColor : Color.white.opacity(0.18)).frame(width: 26, height: 15)
            Circle().fill(Color.white).frame(width: 13, height: 13).padding(1).shadow(radius: 0.5)
        }
        .animation(.easeOut(duration: 0.12), value: c.isOn)
        .contentShape(Rectangle())
        .onTapGesture { c.isOn.toggle() }
    }
}
