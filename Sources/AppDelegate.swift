import AppKit
import Carbon.HIToolbox

/// приложение живёт только в меню-баре, окон и иконки в Dock нет
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let enabledKey = "effectEnabled"
    private static let selectedShaderKey = "selectedShader"

    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private let overlay = OverlayController()
    private let gamma = GammaController()

    private var plugins: [ShaderPlugin] = []
    private var loadErrors: [PluginError] = []
    private var isEnabled = false

    private var selectedIdentifier: String? {
        get { UserDefaults.standard.string(forKey: Self.selectedShaderKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.selectedShaderKey) }
    }

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

        // control + option + command + F
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { [weak self] in
            self?.toggleEffect()
        }

        reloadPlugins()
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            enableEffect()
        }
    }

    // MARK: - плагины

    private func reloadPlugins() {
        let directory = shadersDirectory()
        do {
            try installBundledPlugins(into: directory)
        } catch {
            NSLog("не удалось поставить встроенные пресеты: \(error.localizedDescription)")
        }
        let loaded = loadPlugins(from: directory)
        plugins = loaded.plugins
        loadErrors = loaded.errors
    }

    private var selectedPlugin: ShaderPlugin? {
        plugins.first { $0.identifier == selectedIdentifier } ?? plugins.first
    }

    // MARK: - включение эффекта

    private func enableEffect() {
        guard let plugin = selectedPlugin else {
            showAlert(title: "Нет ни одного шейдера", message: shadersDirectory().path)
            return
        }
        do {
            // уровень плагина выбирает бэкенд, активным остаётся ровно один
            switch plugin.kind {
            case let .gamma(settings):
                overlay.hide()
                try gamma.activate(settings)
                setEnabled(true)
            case .overlay:
                gamma.deactivate()
                try overlay.show(plugin: plugin)
                setEnabled(true)
            case .capture:
                gamma.deactivate()
                startCapture(plugin: plugin)
            }
        } catch {
            disableEffect()
            showAlert(title: "Эффект не запустился", message: error.localizedDescription)
        }
    }

    private func startCapture(plugin: ShaderPlugin) {
        guard ensureScreenRecordingAccess() else {
            disableEffect()
            return
        }
        Task { @MainActor in
            do {
                try await overlay.showCapture(plugin: plugin) { [weak self] error in
                    DispatchQueue.main.async {
                        self?.disableEffect()
                        self?.showAlert(
                            title: "Захват экрана остановлен",
                            message: error.localizedDescription
                        )
                    }
                }
                setEnabled(true)
            } catch {
                disableEffect()
                showAlert(title: "Захват экрана не запустился", message: error.localizedDescription)
            }
        }
    }

    /// свой экран объяснения до системного диалога, как договорились в PLAN.md
    private func ensureScreenRecordingAccess() -> Bool {
        if hasScreenRecordingAccess() {
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        let explanation = NSAlert()
        explanation.messageText = "Этому эффекту нужно разрешение Screen Recording"
        explanation.informativeText = """
        Гамма-таблица умеет менять каналы по отдельности, но не смешивать их, \
        поэтому честный чёрно-белый обязан читать изображение экрана.

        Кадры живут только в памяти до вывода на экран: приложение ничего не пишет \
        на диск и никуда не передаёт.

        Дальше откроется системный диалог, где надо разрешить запись экрана.
        """
        explanation.addButton(withTitle: "Продолжить")
        explanation.addButton(withTitle: "Отмена")
        guard explanation.runModal() == .alertFirstButtonReturn else { return false }

        if requestScreenRecordingAccess() {
            return true
        }

        // системный диалог показывается один раз за установку, дальше только руками
        NSApp.activate(ignoringOtherApps: true)
        let denied = NSAlert()
        denied.messageText = "Разрешение не выдано"
        denied.informativeText = "Откройте «Конфиденциальность и безопасность» → «Запись экрана» и включите ScreenFilter."
        denied.addButton(withTitle: "Открыть настройки")
        denied.addButton(withTitle: "Отмена")
        if denied.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
        return false
    }

    private func disableEffect() {
        overlay.hide()
        gamma.deactivate()
        setEnabled(false)
    }

    /// без этого после выхода экран остался бы перекрашенным
    func applicationWillTerminate(_ notification: Notification) {
        gamma.deactivate()
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        statusItem?.button?.appearsDisabled = !enabled
    }

    @objc private func toggleEffect() {
        if isEnabled {
            disableEffect()
        } else {
            enableEffect()
        }
    }

    @objc private func selectPlugin(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        selectedIdentifier = identifier
        enableEffect()
    }

    @objc private func showLoadError(_ sender: NSMenuItem) {
        guard let message = sender.representedObject as? String else { return }
        showAlert(title: "Шейдер не загрузился", message: message)
    }

    @objc private func openShadersFolder() {
        NSWorkspace.shared.open(shadersDirectory())
    }

    private func showAlert(title: String, message: String) {
        // без активации окно алерта у LSUIElement-приложения уедет за чужие окна
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - меню

    /// пересобирается на каждое открытие: новый шейдер в папке виден без перезапуска
    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadPlugins()
        menu.removeAllItems()

        let toggle = NSMenuItem(
            title: isEnabled ? "Выключить эффект" : "Включить эффект",
            action: #selector(toggleEffect),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let hint = NSMenuItem(title: "Хоткей: ⌃⌥⌘F", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let active = selectedPlugin?.identifier
        for plugin in plugins {
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

        for error in loadErrors {
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

        let folder = NSMenuItem(
            title: "Открыть папку шейдеров",
            action: #selector(openShadersFolder),
            keyEquivalent: ""
        )
        folder.target = self
        menu.addItem(folder)

        menu.addItem(
            withTitle: "Выход",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    }
}
