import AppKit
import Carbon.HIToolbox

/// приложение живёт только в меню-баре, окон и иконки в Dock нет
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let enabledKey = "effectEnabled"
    private static let selectedShaderKey = "selectedShader"

    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private let overlay = OverlayController()

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
            try overlay.show(plugin: plugin)
            setEnabled(true)
        } catch {
            setEnabled(false)
            showAlert(title: "Шейдер не запустился", message: error.localizedDescription)
        }
    }

    private func disableEffect() {
        overlay.hide()
        setEnabled(false)
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
