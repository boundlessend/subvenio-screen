import AppKit
import KeyboardShortcuts

/// приложение живёт только в меню-баре, окон и иконки в Dock нет
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let effects = EffectController()
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "tv",
            accessibilityDescription: "ScreenFilter"
        )
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        KeyboardShortcuts.onKeyDown(for: .toggleEffect) { [weak self] in
            self?.toggleEffect()
        }

        effects.restoreFromDefaults()
        updateStatusIcon()
    }

    /// без этого после выхода экран остался бы перекрашенным
    func applicationWillTerminate(_ notification: Notification) {
        effects.restoreGamma()
    }

    private func updateStatusIcon() {
        statusItem?.button?.appearsDisabled = !effects.isEnabled
    }

    @objc private func toggleEffect() {
        effects.toggle()
        updateStatusIcon()
    }

    @objc private func selectPlugin(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        effects.selectedIdentifier = identifier
        effects.enable()
        updateStatusIcon()
    }

    @objc private func showLoadError(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? String else { return }
        showAlert(title: "Шейдер не загрузился", message: message)
    }

    @objc private func openSettings() {
        settings.show(effects: effects)
    }

    // MARK: - меню

    /// пересобирается на каждое открытие: новый шейдер в папке виден без перезапуска
    func menuNeedsUpdate(_ menu: NSMenu) {
        effects.reload()
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: effects.isEnabled ? "Выключить эффект" : "Включить эффект",
            action: #selector(toggleEffect),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleEffect)
        let hint = NSMenuItem(
            title: shortcut.map { "Хоткей: \($0)" } ?? "Хоткей не назначен",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let active = effects.selectedPlugin?.identifier
        for plugin in effects.plugins {
            let item = NSMenuItem(
                title: plugin.manifest.name,
                action: #selector(selectPlugin(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = plugin.identifier
            item.state = plugin.identifier == active ? .on : .off
            menu.addItem(item)
        }

        for error in effects.loadErrors {
            let item = NSMenuItem(
                title: "⚠ \(error.pluginName)",
                action: #selector(showLoadError(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = error.localizedDescription
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Настройки…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(
            withTitle: "Выход",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }
}
