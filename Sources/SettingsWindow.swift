import AppKit
import KeyboardShortcuts
import Pow
import SwiftUI

struct SettingsView: View {
    @ObservedObject var effects: EffectController
    @ObservedObject var updates: UpdateController
    /// список окон живой и меняется постоянно, поэтому обновляется сам, пока секция видна
    @State private var windows: [TrackedWindow] = availableWindows()
    @State private var launchAtLogin = isLaunchAtLoginEnabled()

    private let windowRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if let plugin = effects.selectedPlugin {
                effectSection(for: plugin)
                placementSection(for: plugin)
                if plugin.manifest.level == .capture {
                    captureSection(for: plugin)
                }
            } else {
                Section {
                    Text("No presets available")
                        .foregroundStyle(.secondary)
                    Button("Open shaders folder") {
                        NSWorkspace.shared.open(shadersDirectory())
                    }
                }
            }

            generalSection
            updateSection

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
        .formStyle(.grouped)
        .frame(minWidth: 700, minHeight: 560)
    }

    /// пресет, его параметры и превью рядом с ними: ползунок и результат в одном месте
    @ViewBuilder
    private func effectSection(for plugin: ShaderPlugin) -> some View {
        Section("Effect") {
            Picker("Preset", selection: Binding(
                get: { effects.selectedIdentifier ?? plugin.identifier },
                // анимация нужна самому переходу превью: без транзакции SwiftUI
                // подменит картинку мгновенно
                set: { identifier in
                    withAnimation(.easeInOut(duration: 0.35)) {
                        effects.selectedIdentifier = identifier
                    }
                }
            )) {
                ForEach(effects.plugins, id: \.identifier) { item in
                    Text(item.manifest.name).tag(item.identifier)
                }
            }

            Text(levelDescription(plugin.manifest.level))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 20) {
                parameterControls(for: plugin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                EffectPreview(plugin: plugin, parameters: effects.parameters(for: plugin))
                    .frame(width: 260, height: 150)
                    .id(plugin.identifier)
                    // смена пресета как смена кадра плёнки: по теме и заодно скрывает
                    // паузу на компиляцию нового шейдера
                    .transition(.movingParts.filmExposure)
            }

            HStack(spacing: 12) {
                if plugin.manifest.parameters?.isEmpty == false {
                    Button("Reset to defaults") {
                        effects.resetParameters(for: plugin)
                    }
                }
                Button("Open shaders folder") {
                    NSWorkspace.shared.open(shadersDirectory())
                }
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            // проверка конфликтов с системными комбинациями идёт из коробки
            KeyboardShortcuts.Recorder("Toggle effect:", name: .toggleEffect)

            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLoginSafely($0) }
            ))
        }
    }

    @ViewBuilder
    private func placementSection(for plugin: ShaderPlugin) -> some View {
        Section("Where it lands") {
            Picker("Display:", selection: $effects.selectedDisplayID) {
                ForEach(effects.displays) { display in
                    Text(display.name).tag(display.id)
                }
            }

            Toggle("Only under the selected window", isOn: $effects.windowModeEnabled)

            if effects.windowModeEnabled {
                windowControls(for: plugin)
            }
        }
    }

    /// обновления идут через страницу релизов GitHub: приложение только сообщает
    /// о новой версии и открывает браузер, ничего не скачивая само
    private var updateSection: some View {
        Section("Updates") {
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

            if let error = updates.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
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

    @ViewBuilder
    private func captureSection(for plugin: ShaderPlugin) -> some View {
        Section("Capture") {
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

    @ViewBuilder
    private func windowControls(for plugin: ShaderPlugin) -> some View {
        if plugin.manifest.level == .gammaLUT {
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
                        Text(parameter.name)
                            .frame(width: 130, alignment: .leading)
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

/// окно настроек живёт отдельно от меню-бара и создаётся один раз
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(effects: EffectController, updates: UpdateController) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Subvenio Screen Settings")
            window.contentView = NSHostingView(rootView: SettingsView(effects: effects, updates: updates))
            window.delegate = self
            window.isReleasedWhenClosed = false
            // размер и положение окна переживают перезапуск
            window.setFrameAutosaveName("SettingsWindow")
            if window.frame.origin == .zero {
                window.center()
            }
            self.window = window
        }
        activateApp()
        window?.makeKeyAndOrderFront(nil)
    }

    /// окно закрылось: приложение возвращается в меню-бар и уходит из ⌘Tab
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
