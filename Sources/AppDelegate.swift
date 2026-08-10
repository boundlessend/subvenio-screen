import AppKit
import Combine
import KeyboardShortcuts

/// приложение живёт только в меню-баре, окон и иконки в Dock нет
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let didShowWelcomeKey = "didShowWelcome"

    private var statusItem: NSStatusItem?
    private let effects = EffectController()
    private let updates = UpdateController()
    private let settings = SettingsWindowController()
    private var observers: Set<AnyCancellable> = []
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // положение иконки в меню-баре переживает перезапуск
        item.autosaveName = "SubvenioScreenStatusItem"
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
        scheduleUpdateChecks()
    }

    /// проверка при запуске и раз в час: приложение живёт неделями, и без тика
    /// недельный интервал наступал бы только при перезапуске
    private func scheduleUpdateChecks() {
        Task { await updates.checkIfDue() }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.updates.checkIfDue() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
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
        // свой силуэт вместо системного символа: та же форма, что у иконки приложения.
        // template-режим означает, что цвет выбирает меню-бар, а не мы
        let image = effects.status == nil
            ? NSImage(named: "MenuBarIcon")
            : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "Subvenio Screen"
        button.image = image
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

    /// выбор пресета это выбор, а не включение: работающий эффект подменится сам,
    /// выключенный останется выключенным и не потянет за собой запрос разрешения
    @objc private func selectPlugin(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        effects.selectedIdentifier = identifier
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

    /// приложение ничего не скачивает и не ставит само: открывает страницу релиза
    @objc private func openReleasePage() {
        guard let release = updates.available else { return }
        NSWorkspace.shared.open(release.url)
    }

    @objc private func openSettings() {
        // на время открытого окна приложение становится обычным: появляется ⌘Tab
        // и собственное меню, иначе окно теряется за чужими
        NSApp.setActivationPolicy(.regular)
        settings.show(effects: effects, updates: updates)
    }

    /// стандартная панель берёт имя, версию и копирайт из Info.plist,
    /// а credits это единственное место, куда влезает описание
    @objc private func showAbout() {
        activateApp()
        let description = String(localized: "old glass over a new screen")
        let credits = NSAttributedString(
            string: description,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - меню

    /// символ в размер строки меню. template означает, что цвет берётся у меню,
    /// поэтому иконка сама тускнеет у выключенных пунктов и белеет на подсветке
    private func menuIcon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }

    /// символ пресета берётся из манифеста, но выдуманное имя даёт пустую картинку,
    /// поэтому запасной вариант это уровень: он говорит, чего пресет стоит -
    /// таблица дисплея, слой поверх экрана или чтение картинки с разрешением
    private func pluginIcon(_ plugin: ShaderPlugin) -> NSImage? {
        if let name = plugin.manifest.icon, let image = menuIcon(name) {
            return image
        }
        switch plugin.manifest.level {
        case .gammaLUT: return menuIcon("circle.lefthalf.filled")
        case .overlay: return menuIcon("square.on.square")
        case .capture: return menuIcon("camera.viewfinder")
        }
    }

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
        toggle.image = menuIcon("camera.filters")
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
        hint.image = menuIcon("keyboard")
        menu.addItem(hint)

        if let status = effects.status {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: status.title,
                action: #selector(showStatusDetails),
                keyEquivalent: ""
            )
            item.target = self
            item.image = menuIcon("exclamationmark.triangle")
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
            item.image = pluginIcon(plugin)
            menu.addItem(item)
        }

        for error in effects.loadErrors {
            let item = NSMenuItem(
                title: error.pluginName,
                action: #selector(showLoadError(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = error.localizedDescription
            item.image = menuIcon("exclamationmark.triangle")
            menu.addItem(item)
        }

        if let release = updates.available {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: String(
                    format: String(localized: "Version %@ is available"),
                    release.version
                ),
                action: #selector(openReleasePage),
                keyEquivalent: ""
            )
            item.target = self
            item.image = menuIcon("arrow.down.circle")
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = menuIcon("gearshape")
        menu.addItem(settingsItem)

        let about = NSMenuItem(
            title: String(localized: "About Subvenio Screen"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        about.image = menuIcon("info.circle")
        menu.addItem(about)

        let quit = menu.addItem(
            withTitle: String(localized: "Quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.image = menuIcon("power")
    }
}
