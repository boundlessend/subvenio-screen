import AppKit
import Combine
import KeyboardShortcuts

/// приложение живёт только в меню-баре, окон и иконки в Dock нет
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let didShowWelcomeKey = "didShowWelcome"

    private var statusItem: NSStatusItem?
    private let effects = EffectController()
    private let settings = SettingsWindowController()
    private var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // положение иконки в меню-баре переживает перезапуск
        item.autosaveName = "SubvenireScreenStatusItem"
        // левый клик переключает эффект, правый открывает меню: самое частое действие
        // не должно стоить открытия меню
        item.button?.action = #selector(statusItemClicked)
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        KeyboardShortcuts.onKeyDown(for: .toggleEffect) { [weak self] in
            self?.toggleEffect()
        }

        effects.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusIcon() }
            .store(in: &observers)

        effects.restoreFromDefaults()
        updateStatusIcon()
        showWelcomeOnFirstLaunch()
    }

    /// без этого после выхода экран остался бы перекрашенным
    func applicationWillTerminate(_ notification: Notification) {
        effects.flushParameters()
        effects.restoreGamma()
    }

    /// меню-бар без Dock-иконки при первом запуске выглядит так, будто ничего не случилось
    private func showWelcomeOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.didShowWelcomeKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.didShowWelcomeKey)
        openSettings()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name = effects.status == nil ? "tv" : "exclamationmark.triangle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Subvenire Screen")
        button.appearsDisabled = !effects.isEnabled && effects.status == nil
        button.toolTip = effects.status?.title ?? effects.selectedPlugin?.manifest.name
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        // control плюс клик это тот же контекстный жест, что и правая кнопка,
        // и единственный доступный на мыши без второй кнопки
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showMenu()
        } else {
            toggleEffect()
        }
    }

    /// меню живёт только на время показа: постоянное menu у статус-итема перехватывает
    /// левый клик и не даёт переключать эффект одним движением
    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
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

    @objc private func showStatusDetails() {
        guard let status = effects.status else { return }
        showAlert(title: status.title, message: status.message)
        effects.clearStatus()
        updateStatusIcon()
    }

    @objc private func showLoadError(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? String else { return }
        showAlert(title: String(localized: "Shader failed to load"), message: message)
    }

    @objc private func openSettings() {
        // на время открытого окна приложение становится обычным: появляется ⌘Tab
        // и собственное меню, иначе окно теряется за чужими
        NSApp.setActivationPolicy(.regular)
        settings.show(effects: effects)
    }

    @objc private func showAbout() {
        activateApp()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - меню

    /// пересобирается на каждое открытие. список пресетов держит в актуальном виде
    /// наблюдатель за папкой, поэтому диска здесь не касаемся
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: effects.isEnabled
                ? String(localized: "Turn Effect Off")
                : String(localized: "Turn Effect On"),
            action: #selector(toggleEffect),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleEffect)
        let hint = NSMenuItem(
            title: shortcut.map {
                String(format: String(localized: "Hotkey: %@"), $0.description)
            } ?? String(localized: "No hotkey assigned"),
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        if let status = effects.status {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "⚠ \(status.title)",
                action: #selector(showStatusDetails),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

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
            title: String(localized: "Settings…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let about = NSMenuItem(
            title: String(localized: "About Subvenire Screen"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(
            withTitle: String(localized: "Quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }
}
