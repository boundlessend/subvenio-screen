import AppKit
import SwiftUI

// MARK: - окно

/// окно настроек живёт отдельно от меню-бара и создаётся один раз.
/// вкладки сверху это стандартный стиль настроек macOS: тулбар со стилем preference
/// система рисует и подсвечивает сама
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingView<SettingsRoot>?
    private var effects: EffectController?
    private var updates: UpdateController?
    private var tab: SettingsTab = .effect

    /// tab равный nil означает «открыть на том, что было»: за человека выбирают вкладку
    /// только когда его привёл сюда конкретный вопрос вроде смены комбинации
    func show(effects: EffectController, updates: UpdateController, tab: SettingsTab?) {
        self.effects = effects
        self.updates = updates

        if window == nil {
            let hosting = NSHostingView(
                rootView: SettingsRoot(tab: self.tab, effects: effects, updates: updates)
            )
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                // размер задаёт вкладка, поэтому тянуть окно руками незачем
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            // содержимое выше экрана иначе уносило бы кнопки за нижний край:
            // список непрочитанных пресетов растёт линейно и потолка не имеет
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.documentView = hosting
            window.contentView = scroll

            window.delegate = self
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .preference

            let toolbar = NSToolbar(identifier: "SettingsToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar

            // положение окна переживает перезапуск, размер берётся у вкладки
            window.setFrameAutosaveName("SettingsWindow")
            if window.frame.origin == .zero {
                window.center()
            }
            self.hosting = hosting
            self.window = window
        }

        select(tab ?? self.tab)
        activateApp()
        window?.makeKeyAndOrderFront(nil)
    }

    /// окно закрылось: приложение возвращается в меню-бар и уходит из ⌘Tab
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - вкладки

    private func select(_ tab: SettingsTab) {
        guard let window, let hosting, let effects, let updates else { return }
        self.tab = tab

        hosting.rootView = SettingsRoot(tab: tab, effects: effects, updates: updates)
        // вкладка сама называет окно, как это делают настройки системы
        window.title = tab.title
        window.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)

        // высота нового содержимого известна только после укладки
        hosting.layoutSubtreeIfNeeded()
        resize(to: hosting.fittingSize)
    }

    /// окно растёт и сжимается вниз: верхний край остаётся там, где человек его оставил.
    /// выше рабочей области экрана оно не растёт - остаток доезжает прокруткой,
    /// и за нижний край не уходит, иначе кнопки уезжают под Dock
    private func resize(to size: NSSize) {
        guard let window, let hosting else { return }
        // содержимое живёт в NSScrollView, поэтому свой размер оно должно задать само
        hosting.frame = NSRect(origin: .zero, size: size)

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let chrome = window.frame.height - (window.contentView?.frame.height ?? 0)
        let available = visible?.height ?? size.height
        let height = min(size.height, max(available - chrome, 200))

        var frame = window.frame
        let delta = height - frame.height + chrome
        guard abs(delta) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        frame.size.height += delta
        frame.origin.y -= delta
        frame.size.width = size.width
        if let visible, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(tab)
    }

    private var identifiers: [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }
}
