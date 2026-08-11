import AppKit
import KeyboardShortcuts
import Pow
import SwiftUI

/// вкладки окна настроек. тулбар рисует система, поэтому здесь только имя и символ
enum SettingsTab: String, CaseIterable {
    case effect, placement, capture, general, updates

    var title: String {
        switch self {
        case .effect: return String(localized: "Effect")
        case .placement: return String(localized: "Placement")
        case .capture: return String(localized: "Capture")
        case .general: return String(localized: "General")
        case .updates: return String(localized: "Updates")
        }
    }

    var symbol: String {
        switch self {
        case .effect: return "camera.filters"
        case .placement: return "macwindow"
        case .capture: return "camera.viewfinder"
        case .general: return "gearshape"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// одно содержимое на вкладку. ширина фиксирована, высоту окно берёт у той вкладки,
/// которую сейчас показывает
struct SettingsRoot: View {
    /// ширину задаёт самая тесная строка: три кнопки под превью, где русские надписи
    /// длиннее английских и на 620 точках последняя обрезалась
    static let width: CGFloat = 668

    let tab: SettingsTab
    @ObservedObject var effects: EffectController
    @ObservedObject var updates: UpdateController

    var body: some View {
        Group {
            switch tab {
            case .effect: EffectSettings(effects: effects)
            case .placement: PlacementSettings(effects: effects)
            case .capture: CaptureSettings(effects: effects)
            case .general: GeneralSettings()
            case .updates: UpdateSettings(updates: updates)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
    }
}

// MARK: - эффект

struct EffectSettings: View {
    @ObservedObject var effects: EffectController
    @State private var isConfirmingRestore = false

    var body: some View {
        Form {
            if effects.plugins.isEmpty {
                Section {
                    Text("No presets available")
                        .foregroundStyle(.secondary)
                    presetButtons
                }
            } else {
                mainSection
            }

            if !effects.loadErrors.isEmpty {
                Section("Failed to load") {
                    ForEach(effects.loadErrors.indices, id: \.self) { index in
                        Text(effects.loadErrors[index].localizedDescription)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// пресет, переключатель, параметры и превью рядом с ними: выбор, ползунок
    /// и результат в одном месте
    @ViewBuilder
    private var mainSection: some View {
        Section {
            Picker("Preset", selection: Binding(
                get: { effects.selectedIdentifier ?? effects.plugins.first?.identifier ?? "" },
                // анимация нужна самому переходу превью: без транзакции SwiftUI
                // подменит картинку мгновенно
                set: { identifier in
                    withAnimation(.easeInOut(duration: 0.35)) {
                        effects.selectedIdentifier = identifier
                    }
                }
            )) {
                // те же группы, что в меню-баре: семнадцать имён подряд читаются
                // как список файлов, а по уровню видно, чего пресет стоит
                ForEach(RenderLevel.allCases, id: \.self) { level in
                    Section(level.groupTitle) {
                        ForEach(effects.plugins.filter { $0.manifest.level == level },
                                id: \.identifier) { item in
                            Text(item.manifest.name).tag(item.identifier)
                        }
                    }
                }
            }

            // включение живёт и в меню-баре, и на хоткее, но человек, открывший настройки,
            // ищет его здесь: без переключателя окно показывает эффект, не умея его применить
            Toggle("Effect on screen", isOn: Binding(
                get: { effects.isEnabled },
                set: { $0 ? effects.enable() : effects.disable() }
            ))

            if let plugin = effects.selectedPlugin {
                Text(levelDescription(plugin.manifest.level))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // ползунков обычно меньше, чем высоты у превью: по центру пустота
                // делится поровну и не выглядит забытым местом
                HStack(alignment: .center, spacing: 20) {
                    parameterControls(for: plugin)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    EffectPreview(plugin: plugin, parameters: effects.parameters(for: plugin))
                        .frame(width: 240, height: 138)
                        .id(plugin.identifier)
                        // смена пресета как смена кадра плёнки: по теме и заодно скрывает
                        // паузу на компиляцию нового шейдера
                        .transition(.movingParts.filmExposure)
                }
            } else {
                Text("The selected preset is no longer in the shaders folder. Pick another one.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                if effects.selectedPlugin?.manifest.parameters?.isEmpty == false,
                   let plugin = effects.selectedPlugin {
                    Button("Reset to defaults") {
                        effects.resetParameters(for: plugin)
                    }
                }
                presetButtons
            }
        }
    }

    /// путь к своим пресетам и путь назад к встроенным
    private var presetButtons: some View {
        HStack(spacing: 12) {
            Button("Open shaders folder") {
                NSWorkspace.shared.open(shadersDirectory())
            }
            Button("Restore bundled presets") {
                isConfirmingRestore = true
            }
            .confirmationDialog(
                "Restore the bundled presets?",
                isPresented: $isConfirmingRestore
            ) {
                Button("Restore", role: .destructive) { effects.restoreBundled() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your edits to the bundled presets will be lost. Presets you added yourself are left alone.")
            }
        }
    }

    @ViewBuilder
    private func parameterControls(for plugin: ShaderPlugin) -> some View {
        let parameters = plugin.manifest.parameters ?? []
        if parameters.isEmpty {
            Text("This preset has no parameters: level 1 is configured by the gamma section of its manifest.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let values = effects.parameters(for: plugin)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(parameters.enumerated()), id: \.offset) { index, parameter in
                    HStack(spacing: 10) {
                        Text(parameterTitle(parameter.name))
                            .frame(width: 118, alignment: .leading)
                            .lineLimit(1)
                        Slider(
                            value: Binding(
                                get: { Double(values[index]) },
                                set: { effects.setParameter(Float($0), at: index, for: plugin) }
                            ),
                            in: Double(parameter.min)...Double(parameter.max)
                        )
                        // формат числа берёт разделитель из локали, а не из POSIX
                        Text(values[index].formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// имя параметра в манифесте это идентификатор для шейдера, и в окне оно читается
    /// как код: grainStrength вместо Grain Strength. слова остаются те же, чтобы автор
    /// пресета узнал своё имя, меняются только пробелы и первая буква
    private func parameterTitle(_ name: String) -> String {
        let spaced = name.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private func levelDescription(_ level: RenderLevel) -> String {
        switch level {
        case .gammaLUT:
            return String(localized: "Level 1: gamma table. Covers the cursor, the menu bar and the Dock, and costs nothing.")
        case .overlay:
            return String(localized: "Level 2: a transparent layer above the screen. Needs no permissions.")
        case .capture:
            return String(localized: "Level 3: reads the picture on screen. Needs Screen Recording permission.")
        }
    }
}

// MARK: - размещение

struct PlacementSettings: View {
    @ObservedObject var effects: EffectController
    /// список окон живой и меняется постоянно, поэтому обновляется сам, пока вкладка видна
    @State private var windows: [TrackedWindow] = availableWindows()

    private let windowRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("Display:", selection: $effects.selectedDisplayID) {
                    ForEach(effects.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }

                Toggle("Only under the selected window", isOn: $effects.windowModeEnabled)

                if effects.windowModeEnabled {
                    if effects.selectedPlugin?.manifest.level == .gammaLUT {
                        Text("Level 1 rewrites the table of the whole display and cannot be confined to a window, so this preset stays full-screen.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Picker("Window:", selection: $effects.trackedWindowID) {
                            Text("none").tag(CGWindowID?.none)
                            ForEach(windows, id: \.id) { window in
                                Text(window.title).tag(CGWindowID?.some(window.id))
                            }
                        }
                        Button("Refresh") { windows = availableWindows() }
                    }
                    .onReceive(windowRefresh) { _ in windows = availableWindows() }
                }
            }
        }
    }
}

// MARK: - захват

struct CaptureSettings: View {
    @ObservedObject var effects: EffectController

    var body: some View {
        Form {
            Section {
                // курсор хранится у пресета, а размер и частота общие: настройки уровня 3
                // имеют смысл и тогда, когда выбран пресет попроще
                if let plugin = effects.selectedPlugin, plugin.manifest.level == .capture {
                    Toggle(
                        "Apply the effect to the cursor",
                        isOn: Binding(
                            get: { effects.showsCursor(for: plugin) },
                            set: { effects.setShowsCursor($0, for: plugin) }
                        )
                    )
                    Text("The cursor moves inside the captured frame and lags by the whole pipeline delay, which reads as a laggy mouse.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The selected preset does not read the screen. These settings apply to level 3 presets.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Picker("Capture size:", selection: Binding(
                    get: { effects.captureQuality.scale },
                    set: { effects.captureQuality = CaptureQuality(scale: $0, frameRateCap: effects.captureQuality.frameRateCap) }
                )) {
                    Text("Full resolution").tag(1.0)
                    Text("Three quarters").tag(0.75)
                    Text("Half").tag(0.5)
                }

                Picker("Capture rate:", selection: Binding(
                    get: { effects.captureQuality.frameRateCap },
                    set: { effects.captureQuality = CaptureQuality(scale: effects.captureQuality.scale, frameRateCap: $0) }
                )) {
                    Text("Display refresh rate").tag(0)
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }

                Text("A smaller buffer and a lower rate cost the machine much less, and on a retro effect the difference is hard to see.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - основные

struct GeneralSettings: View {
    @State private var launchAtLogin = isLaunchAtLoginEnabled()

    var body: some View {
        Form {
            Section {
                // проверка конфликтов с системными комбинациями идёт из коробки
                KeyboardShortcuts.Recorder("Toggle effect:", name: .toggleEffect)

                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLoginSafely($0) }
                ))
            }
        }
    }

    private func setLaunchAtLoginSafely(_ enabled: Bool) {
        do {
            try setLaunchAtLogin(enabled)
        } catch {
            showAlert(
                title: String(localized: "Could not change launch at login"),
                message: error.localizedDescription
            )
        }
        // состояние берём у системы, а не у переключателя: регистрация могла не пройти
        launchAtLogin = isLaunchAtLoginEnabled()
    }
}

// MARK: - обновления

/// обновления идут через страницу релизов GitHub: приложение только сообщает
/// о новой версии и открывает браузер, ничего не скачивая само
struct UpdateSettings: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Form {
            Section {
                Picker("Check for updates:", selection: $updates.interval) {
                    ForEach(UpdateInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }

                HStack(spacing: 12) {
                    Button("Check now") {
                        Task { await updates.checkNow() }
                    }
                    .disabled(updates.isChecking)
                    // проверка тихая и почти мгновенная: без отклика непонятно, случилась ли она
                    .changeEffect(.shine, value: updates.lastCheck)

                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else if let release = updates.available {
                        Button(String(format: String(localized: "Download %@"), release.version)) {
                            NSWorkspace.shared.open(release.url)
                        }
                        .transition(.movingParts.pop(Color.accentColor))
                    }
                }
                .animation(.spring(duration: 0.4), value: updates.available?.version)

                if let failure = updates.lastFailure {
                    Text(failure.message)
                        .font(.callout)
                        // отсутствие релизов это ответ, а не сбой: красным здесь пугать нечем
                        .foregroundStyle(failure.isMissingRelease ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                } else if updates.available == nil, let last = updates.lastCheck {
                    Text(String(
                        format: String(localized: "Up to date. Last checked %@"),
                        last.formatted(date: .abbreviated, time: .shortened)
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

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

    func show(effects: EffectController, updates: UpdateController) {
        self.effects = effects
        self.updates = updates

        if window == nil {
            let hosting = NSHostingView(
                rootView: SettingsRoot(tab: tab, effects: effects, updates: updates)
            )
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                // размер задаёт вкладка, поэтому тянуть окно руками незачем
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
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

        select(tab)
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

    /// окно растёт и сжимается вниз: верхний край остаётся там, где человек его оставил
    private func resize(to size: NSSize) {
        guard let window, let hosting else { return }
        let delta = size.height - hosting.frame.height
        guard abs(delta) > 0.5 else { return }

        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
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
