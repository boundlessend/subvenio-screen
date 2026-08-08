import AppKit

/// приложение живёт только в меню-баре, окон и иконки в Dock нет
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "tv",
            accessibilityDescription: "ScreenFilter"
        )
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let placeholder = NSMenuItem(title: "Эффект выключен", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        menu.addItem(placeholder)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Выход",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }
}
