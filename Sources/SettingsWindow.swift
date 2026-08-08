import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var effects: EffectController
    /// список окон живой и меняется постоянно, поэтому обновляется сам, пока секция видна
    @State private var windows: [TrackedWindow] = availableWindows()
    @State private var launchAtLogin = isLaunchAtLoginEnabled()

    private let windowRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
                    HStack(spacing: 6) {
                        // какой пресет сейчас работает: выделение в списке это выбор,
                        // а не состояние эффекта
                        Image(systemName: isRunning(plugin) ? "circle.fill" : "circle")
                            .font(.system(size: 7))
                            .foregroundStyle(isRunning(plugin) ? Color.accentColor : .clear)
                        Text(plugin.manifest.name)
                        Spacer()
                        Text(levelTag(plugin.manifest.level))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .tag(plugin.identifier)
                }
            }

            Button("Open shaders folder") {
                NSWorkspace.shared.open(shadersDirectory())
            }
            .padding(8)
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var details: some View {
        if let plugin = effects.selectedPlugin {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(plugin.manifest.name).font(.title2)
                    Text(levelDescription(plugin.manifest.level))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    parameterControls(for: plugin)

                    if plugin.manifest.level == .capture {
                        captureControls(for: plugin)
                    }

                    Divider()

                    Picker("Display:", selection: $effects.selectedDisplayID) {
                        ForEach(effects.displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .frame(maxWidth: 380)

                    Toggle("Only under the selected window", isOn: $effects.windowModeEnabled)

                    if effects.windowModeEnabled {
                        windowControls(for: plugin)
                    }

                    // проверка конфликтов с системными комбинациями идёт из коробки
                    KeyboardShortcuts.Recorder("Toggle effect:", name: .toggleEffect)

                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLoginSafely($0) }
                    ))

                    if !effects.loadErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Failed to load").font(.headline)
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
            }
        } else {
            Text("No presets available")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func captureControls(for plugin: ShaderPlugin) -> some View {
        Toggle(
            "Apply the effect to the cursor",
            isOn: Binding(
                get: { effects.showsCursor(for: plugin) },
                set: { effects.setShowsCursor($0, for: plugin) }
            )
        )
        Text("The cursor moves inside the captured frame and lags by the whole pipeline delay, which reads as a laggy mouse.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Picker("Capture size:", selection: Binding(
            get: { effects.captureQuality.scale },
            set: { effects.captureQuality = CaptureQuality(scale: $0, frameRateCap: effects.captureQuality.frameRateCap) }
        )) {
            Text("Full resolution").tag(1.0)
            Text("Three quarters").tag(0.75)
            Text("Half").tag(0.5)
        }
        .frame(maxWidth: 380)

        Picker("Capture rate:", selection: Binding(
            get: { effects.captureQuality.frameRateCap },
            set: { effects.captureQuality = CaptureQuality(scale: effects.captureQuality.scale, frameRateCap: $0) }
        )) {
            Text("Display refresh rate").tag(0)
            Text("60 fps").tag(60)
            Text("30 fps").tag(30)
        }
        .frame(maxWidth: 380)

        Text("A smaller buffer and a lower rate cost the machine much less, and on a retro effect the difference is hard to see.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func windowControls(for plugin: ShaderPlugin) -> some View {
        if plugin.manifest.level == .gammaLUT {
            Text("Level 1 rewrites the table of the whole display and cannot be confined to a window, so this preset stays full-screen.")
                .font(.caption)
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
        .frame(maxWidth: 480)
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
                    // формат числа берёт разделитель из локали, а не из POSIX
                    Text(values[index].formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Button("Reset to defaults") {
                effects.resetParameters(for: plugin)
            }
        }
    }

    private func isRunning(_ plugin: ShaderPlugin) -> Bool {
        effects.isEnabled && plugin.identifier == effects.selectedPlugin?.identifier
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

    private func levelTag(_ level: RenderLevel) -> String {
        switch level {
        case .gammaLUT:
            return String(localized: "gamma")
        case .overlay:
            return String(localized: "overlay")
        case .capture:
            return String(localized: "capture")
        }
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

    func show(effects: EffectController) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Subvenire Screen Settings")
            window.contentView = NSHostingView(rootView: SettingsView(effects: effects))
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
