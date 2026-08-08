import AppKit
import Combine

/// состояние эффекта: какой пресет выбран, включён ли он и с какими параметрами.
/// бэкенды выбираются по уровню плагина, активным остаётся ровно один
final class EffectController: ObservableObject {
    private static let enabledKey = "effectEnabled"
    private static let selectedShaderKey = "selectedShader"
    private static let selectedDisplayKey = "selectedDisplay"

    @Published private(set) var plugins: [ShaderPlugin] = []
    @Published private(set) var loadErrors: [PluginError] = []
    @Published private(set) var isEnabled = false

    @Published var selectedIdentifier: String? {
        didSet {
            guard selectedIdentifier != oldValue else { return }
            UserDefaults.standard.set(selectedIdentifier, forKey: Self.selectedShaderKey)
            if isEnabled {
                enable()
            }
        }
    }

    /// на какой монитор кладём эффект. ponytail: один активный эффект на один дисплей.
    /// независимые пресеты на нескольких мониторах сразу потребуют по контроллеру на дисплей
    @Published var selectedDisplayID: CGDirectDisplayID {
        didSet {
            guard selectedDisplayID != oldValue else { return }
            UserDefaults.standard.set(Int(selectedDisplayID), forKey: Self.selectedDisplayKey)
            if isEnabled {
                enable()
            }
        }
    }

    /// эффект только в области выбранного окна вместо всего дисплея
    @Published var windowModeEnabled = false {
        didSet {
            guard windowModeEnabled != oldValue else { return }
            if isEnabled {
                enable()
            } else {
                tracker = nil
            }
        }
    }

    @Published var trackedWindowID: CGWindowID? {
        didSet {
            guard trackedWindowID != oldValue, isEnabled, windowModeEnabled else { return }
            enable()
        }
    }

    private let overlay = OverlayController()
    private let gamma = GammaController()
    private var tracker: WindowTracker?

    init() {
        let storedDisplay = UserDefaults.standard.integer(forKey: Self.selectedDisplayKey)
        selectedDisplayID = storedDisplay > 0 ? CGDirectDisplayID(storedDisplay) : CGMainDisplayID()
        selectedIdentifier = UserDefaults.standard.string(forKey: Self.selectedShaderKey)
        reload()
    }

    var displays: [DisplayChoice] { availableDisplays() }

    var selectedPlugin: ShaderPlugin? {
        plugins.first { $0.identifier == selectedIdentifier } ?? plugins.first
    }

    // MARK: - плагины и параметры

    func reload() {
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

    /// значения параметров: пользовательские из UserDefaults, иначе умолчания манифеста
    func parameters(for plugin: ShaderPlugin) -> [Float] {
        let stored = UserDefaults.standard.array(forKey: parametersKey(plugin)) as? [Double]
        guard let stored, stored.count == plugin.defaultParameters.count else {
            return plugin.defaultParameters
        }
        return stored.map(Float.init)
    }

    func setParameter(_ value: Float, at index: Int, for plugin: ShaderPlugin) {
        var values = parameters(for: plugin)
        guard values.indices.contains(index) else { return }
        values[index] = value
        UserDefaults.standard.set(values.map(Double.init), forKey: parametersKey(plugin))

        if isEnabled, plugin.identifier == selectedPlugin?.identifier {
            overlay.updateParameters(values)
        }
        objectWillChange.send()
    }

    func resetParameters(for plugin: ShaderPlugin) {
        UserDefaults.standard.removeObject(forKey: parametersKey(plugin))
        if isEnabled, plugin.identifier == selectedPlugin?.identifier {
            overlay.updateParameters(plugin.defaultParameters)
        }
        objectWillChange.send()
    }

    private func parametersKey(_ plugin: ShaderPlugin) -> String {
        "params.\(plugin.identifier)"
    }

    /// курсор внутри кадра на уровне 3 отстаёт на всю задержку пайплайна,
    /// поэтому по умолчанию его рисует система поверх эффекта
    func showsCursor(for plugin: ShaderPlugin) -> Bool {
        UserDefaults.standard.bool(forKey: "cursor.\(plugin.identifier)")
    }

    func setShowsCursor(_ value: Bool, for plugin: ShaderPlugin) {
        UserDefaults.standard.set(value, forKey: "cursor.\(plugin.identifier)")
        objectWillChange.send()
        if isEnabled, plugin.identifier == selectedPlugin?.identifier {
            enable()
        }
    }

    // MARK: - включение

    func restoreFromDefaults() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            enable()
        }
    }

    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    func enable() {
        guard let plugin = selectedPlugin else {
            showAlert(
                title: String(localized: "No shaders found"),
                message: shadersDirectory().path
            )
            return
        }

        tracker = nil
        guard let frame = targetFrame(for: plugin) else {
            disable()
            return
        }

        do {
            switch plugin.kind {
            case let .gamma(settings):
                overlay.hide()
                try gamma.activate(settings, displayID: selectedDisplayID)
                setEnabled(true)
            case .overlay:
                gamma.deactivate()
                try overlay.show(
                    plugin: plugin,
                    parameters: parameters(for: plugin),
                    displayID: selectedDisplayID,
                    frame: frame
                )
                startTrackingIfNeeded()
                setEnabled(true)
            case .capture:
                gamma.deactivate()
                startCapture(plugin: plugin, frame: frame)
            }
        } catch {
            disable()
            showAlert(
                title: String(localized: "Effect failed to start"),
                message: error.localizedDescription
            )
        }
    }

    func disable() {
        tracker = nil
        overlay.hide()
        gamma.deactivate()
        setEnabled(false)
    }

    /// область эффекта: рамка выбранного окна или весь дисплей.
    /// уровень 1 живёт в scanout целиком, областью его не ограничить
    private func targetFrame(for plugin: ShaderPlugin) -> CGRect? {
        guard windowModeEnabled, plugin.manifest.level != .gammaLUT else {
            return screen(for: selectedDisplayID)?.frame
        }
        guard let id = trackedWindowID else {
            showAlert(
                title: String(localized: "No window selected"),
                message: String(localized: "Pick a window in settings, or turn off window-only mode.")
            )
            return nil
        }
        guard let frame = windowFrame(id) else {
            showAlert(
                title: String(localized: "Window unavailable"),
                message: String(localized: "The selected window is closed or minimised.")
            )
            return nil
        }
        return frame
    }

    private func startTrackingIfNeeded() {
        guard windowModeEnabled, let id = trackedWindowID else { return }
        tracker = WindowTracker(windowID: id) { [weak self] frame in
            guard let self else { return }
            if let frame {
                self.overlay.updateFrame(frame)
            } else {
                // окно свернули или закрыли: эффект снимается, приложение остаётся работать
                self.disable()
            }
        }
    }

    /// вызывается при выходе: иначе после закрытия экран остался бы перекрашенным
    func restoreGamma() {
        gamma.deactivate()
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    private func startCapture(plugin: ShaderPlugin, frame: CGRect) {
        guard ensureScreenRecordingAccess() else {
            disable()
            return
        }
        Task { @MainActor in
            do {
                try await overlay.showCapture(
                    plugin: plugin,
                    parameters: parameters(for: plugin),
                    displayID: selectedDisplayID,
                    frame: frame,
                    showsCursor: showsCursor(for: plugin)
                ) { [weak self] error in
                    DispatchQueue.main.async {
                        self?.disable()
                        showAlert(
                            title: String(localized: "Screen capture stopped"),
                            message: error.localizedDescription
                        )
                    }
                }
                startTrackingIfNeeded()
                setEnabled(true)
            } catch {
                disable()
                showAlert(
                    title: String(localized: "Screen capture failed to start"),
                    message: error.localizedDescription
                )
            }
        }
    }
}

func showAlert(title: String, message: String) {
    // без активации окно алерта у LSUIElement-приложения уедет за чужие окна
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.runModal()
}

/// свой экран объяснения до системного диалога, как договорились в PLAN.md
private func ensureScreenRecordingAccess() -> Bool {
    if hasScreenRecordingAccess() {
        return true
    }

    NSApp.activate(ignoringOtherApps: true)
    let explanation = NSAlert()
    explanation.messageText = String(localized: "This effect needs Screen Recording permission")
    explanation.informativeText = String(localized: """
    A gamma table can scale channels separately but cannot mix them, so an honest \
    black and white effect has to read the picture on screen.

    Frames only live in memory until they are drawn: nothing is written to disk \
    and nothing leaves your machine.

    The system permission dialog opens next.
    """)
    explanation.addButton(withTitle: String(localized: "Continue"))
    explanation.addButton(withTitle: String(localized: "Cancel"))
    guard explanation.runModal() == .alertFirstButtonReturn else { return false }

    if requestScreenRecordingAccess() {
        return true
    }

    // системный диалог показывается один раз за установку, дальше только руками
    NSApp.activate(ignoringOtherApps: true)
    let denied = NSAlert()
    denied.messageText = String(localized: "Permission not granted")
    denied.informativeText = String(localized: "Open Privacy & Security → Screen Recording and enable ScreenFilter.")
    denied.addButton(withTitle: String(localized: "Open Settings"))
    denied.addButton(withTitle: String(localized: "Cancel"))
    if denied.runModal() == .alertFirstButtonReturn {
        openScreenRecordingSettings()
    }
    return false
}
