import AppKit
import Carbon.HIToolbox

/// приложение живёт только в меню-баре, окон и иконки в Dock нет
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledKey = "effectEnabled"

    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var hotKey: GlobalHotKey?
    private let overlay = OverlayController()

    private var isEnabled = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            overlay.setVisible(isEnabled)
            toggleItem?.title = isEnabled ? "Выключить эффект" : "Включить эффект"
            statusItem?.button?.appearsDisabled = !isEnabled
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "tv",
            accessibilityDescription: "ScreenFilter"
        )
        item.menu = makeMenu()
        statusItem = item

        // control + option + command + F
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { [weak self] in
            self?.toggleEffect()
        }

        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: "Включить эффект",
            action: #selector(toggleEffect),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        let hint = NSMenuItem(title: "Хоткей: ⌃⌥⌘F", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Выход",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    @objc private func toggleEffect() {
        isEnabled.toggle()
    }
}
