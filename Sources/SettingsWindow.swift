import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var effects: EffectController
    /// список окон снимается при открытии и по кнопке: он живой и меняется постоянно
    @State private var windows: [TrackedWindow] = availableWindows()
    @State private var launchAtLogin = isLaunchAtLoginEnabled()

    var body: some View {
        HStack(spacing: 0) {
            presetList
            Divider()
            details
        }
        .frame(minWidth: 640, minHeight: 380)
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(
                get: { effects.selectedIdentifier ?? effects.selectedPlugin?.identifier },
                set: { effects.selectedIdentifier = $0 }
            )) {
                ForEach(effects.plugins, id: \.identifier) { plugin in
                    HStack {
                        Text(plugin.manifest.name)
                        Spacer()
                        Text("ур. \(plugin.manifest.level.rawValue)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .tag(plugin.identifier)
                }
            }

            Button("Открыть папку шейдеров") {
                NSWorkspace.shared.open(shadersDirectory())
            }
            .padding(8)
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var details: some View {
        if let plugin = effects.selectedPlugin {
            VStack(alignment: .leading, spacing: 16) {
                Text(plugin.manifest.name).font(.title2)
                Text(levelDescription(plugin.manifest.level))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                parameterControls(for: plugin)

                if plugin.manifest.level == .capture {
                    Toggle(
                        "Применять эффект к курсору",
                        isOn: Binding(
                            get: { effects.showsCursor(for: plugin) },
                            set: { effects.setShowsCursor($0, for: plugin) }
                        )
                    )
                    Text("Курсор попадёт внутрь кадра и будет отставать на всю задержку захвата: это ощущается как лаг мыши.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Picker("Монитор:", selection: $effects.selectedDisplayID) {
                    ForEach(effects.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .frame(maxWidth: 380)

                Toggle("Только под выбранным окном", isOn: $effects.windowModeEnabled)

                if effects.windowModeEnabled {
                    if plugin.manifest.level == .gammaLUT {
                        Text("Уровень 1 меняет таблицу всего дисплея, областью окна его ограничить нельзя: этот пресет останется на весь экран.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Picker("Окно:", selection: $effects.trackedWindowID) {
                            Text("не выбрано").tag(CGWindowID?.none)
                            ForEach(windows, id: \.id) { window in
                                Text(window.title).tag(CGWindowID?.some(window.id))
                            }
                        }
                        Button("Обновить") { windows = availableWindows() }
                    }
                    .frame(maxWidth: 480)
                }

                // проверка конфликтов с системными комбинациями идёт из коробки
                KeyboardShortcuts.Recorder("Переключить эффект:", name: .toggleEffect)

                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLoginSafely($0) }
                ))

                Spacer()

                if !effects.loadErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Не загрузились").font(.headline)
                        ForEach(effects.loadErrors.indices, id: \.self) { index in
                            Text(effects.loadErrors[index].localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Нет ни одного пресета")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func parameterControls(for plugin: ShaderPlugin) -> some View {
        let parameters = plugin.manifest.parameters ?? []
        if parameters.isEmpty {
            Text("У этого пресета нет параметров: уровень 1 настраивается секцией gamma в манифесте.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let values = effects.parameters(for: plugin)
            ForEach(Array(parameters.enumerated()), id: \.offset) { index, parameter in
                HStack(spacing: 12) {
                    Text(parameter.name).frame(width: 160, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(values[index]) },
                            set: { effects.setParameter(Float($0), at: index, for: plugin) }
                        ),
                        in: Double(parameter.min)...Double(parameter.max)
                    )
                    Text(String(format: "%.2f", values[index]))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Button("Сбросить к умолчаниям") {
                effects.resetParameters(for: plugin)
            }
        }
    }

    private func setLaunchAtLoginSafely(_ enabled: Bool) {
        do {
            try setLaunchAtLogin(enabled)
        } catch {
            showAlert(title: "Не удалось изменить автозапуск", message: error.localizedDescription)
        }
        // состояние берём у системы, а не у переключателя: регистрация могла не пройти
        launchAtLogin = isLaunchAtLoginEnabled()
    }

    private func levelDescription(_ level: RenderLevel) -> String {
        switch level {
        case .gammaLUT:
            return "Уровень 1: гамма-таблица. Покрывает курсор, меню-бар и Dock, ничего не стоит по нагрузке."
        case .overlay:
            return "Уровень 2: прозрачный слой поверх экрана. Разрешений не требует."
        case .capture:
            return "Уровень 3: читает изображение экрана. Требует разрешения Screen Recording."
        }
    }
}

/// окно настроек живёт отдельно от меню-бара и создаётся один раз
final class SettingsWindowController {
    private var window: NSWindow?

    func show(effects: EffectController) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Настройки ScreenFilter"
            window.contentView = NSHostingView(rootView: SettingsView(effects: effects))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
