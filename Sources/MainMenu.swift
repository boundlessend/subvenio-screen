import AppKit

/// строка меню приложения. приложение живёт в меню-баре и обычно её не показывает,
/// но на время открытого окна настроек становится обычным - и тогда без этой строки
/// не работают ни ⌘W, ни ⌘Q, ни ⌘C, то есть текст ошибки шейдера нечем скопировать,
/// хотя выделять его окно разрешает
@MainActor
func makeMainMenu(target: AnyObject, settingsAction: Selector, aboutAction: Selector) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(appMenu(target: target, settingsAction: settingsAction, aboutAction: aboutAction))
    menu.addItem(editMenu())
    menu.addItem(windowMenu())
    return menu
}

private func submenu(_ title: String) -> (item: NSMenuItem, menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    item.submenu = menu
    return (item, menu)
}

@MainActor
private func appMenu(target: AnyObject, settingsAction: Selector, aboutAction: Selector) -> NSMenuItem {
    // имя приложения система в программно собранное меню не подставляет, в отличие от NIB
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? ProcessInfo.processInfo.processName
    let (item, menu) = submenu(name)

    let about = menu.addItem(
        withTitle: String(format: String(localized: "About %@"), name),
        action: aboutAction,
        keyEquivalent: ""
    )
    about.target = target

    menu.addItem(.separator())
    let settings = menu.addItem(
        withTitle: String(localized: "Settings…"),
        action: settingsAction,
        keyEquivalent: ","
    )
    settings.target = target

    menu.addItem(.separator())
    menu.addItem(
        withTitle: String(format: String(localized: "Hide %@"), name),
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"
    )
    let hideOthers = menu.addItem(
        withTitle: String(localized: "Hide Others"),
        action: #selector(NSApplication.hideOtherApplications(_:)),
        keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]

    menu.addItem(.separator())
    menu.addItem(
        withTitle: String(format: String(localized: "Quit %@"), name),
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    return item
}

/// без него ⌘C не копирует ни текст ошибки шейдера, ни путь к папке пресетов.
/// пункты уходят по responder chain, поэтому цели у них нет
private func editMenu() -> NSMenuItem {
    let (item, menu) = submenu(String(localized: "Edit"))

    menu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    let redo = menu.addItem(
        withTitle: String(localized: "Redo"),
        action: Selector(("redo:")),
        keyEquivalent: "z"
    )
    redo.keyEquivalentModifierMask = [.command, .shift]

    menu.addItem(.separator())
    menu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(
        withTitle: String(localized: "Select All"),
        action: #selector(NSText.selectAll(_:)),
        keyEquivalent: "a"
    )
    return item
}

private func windowMenu() -> NSMenuItem {
    let (item, menu) = submenu(String(localized: "Window"))

    menu.addItem(
        withTitle: String(localized: "Close"),
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )
    menu.addItem(
        withTitle: String(localized: "Minimize"),
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"
    )
    return item
}
