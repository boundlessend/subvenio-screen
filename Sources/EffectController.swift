import AppKit
import Combine

/// проблема, о которой надо сказать пользователю. фоновое приложение без окна не имеет
/// права перекрывать чужую работу модальным диалогом, поэтому статус живёт в меню-баре
struct EffectStatus {
    let title: String
    let message: String
}

/// состояние эффекта: какой пресет выбран, включён ли он и с какими параметрами.
/// бэкенды выбираются по уровню плагина, активным остаётся ровно один.
/// живёт на главном акторе: трогает окна, таймеры и публикует состояние в UI
@MainActor
final class EffectController: ObservableObject {
    private static let enabledKey = "effectEnabled"
    private static let selectedShaderKey = "selectedShader"
    private static let selectedDisplayKey = "selectedDisplay"
    private static let captureScaleKey = "capture.scale"
    private static let captureFrameRateKey = "capture.frameRateCap"

    @Published private(set) var plugins: [ShaderPlugin] = []
    @Published private(set) var loadErrors: [PluginError] = []
    @Published private(set) var isEnabled = false
    @Published private(set) var status: EffectStatus?
    /// список экранов меняется редко, а читается на каждый перерасчёт настроек
    @Published private(set) var displays: [DisplayChoice] = availableDisplays()

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

    /// общий рычаг нагрузки уровня 3, а не свойство пресета: слабой машине нужен
    /// половинный буфер для любого шейдера захвата
    @Published var captureQuality: CaptureQuality {
        didSet {
            guard captureQuality != oldValue else { return }
            UserDefaults.standard.set(captureQuality.scale, forKey: Self.captureScaleKey)
            UserDefaults.standard.set(captureQuality.frameRateCap, forKey: Self.captureFrameRateKey)
            if isEnabled, selectedPlugin?.manifest.level == .capture {
                enable()
            }
        }
    }

    private let overlay = OverlayController()
    private let gamma = GammaController()
    private let settings = PluginSettings()
    private var tracker: WindowTracker?
    private var watcher: PluginWatcher?
    /// запуск уровня 3 асинхронный: без этого второй хоткей поднимает второй поток захвата
    private var isStarting = false

    init() {
        let defaults = UserDefaults.standard
        let storedDisplay = defaults.integer(forKey: Self.selectedDisplayKey)
        selectedDisplayID = storedDisplay > 0 ? CGDirectDisplayID(storedDisplay) : CGMainDisplayID()
        selectedIdentifier = defaults.string(forKey: Self.selectedShaderKey)
        let storedScale = defaults.double(forKey: Self.captureScaleKey)
        captureQuality = CaptureQuality(
            scale: storedScale > 0 ? storedScale : 1,
            frameRateCap: defaults.integer(forKey: Self.captureFrameRateKey)
        )

        reload()
        watcher = PluginWatcher(directory: shadersDirectory()) { [weak self] in
            self?.reload()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// без отката на первый попавшийся пресет: выбор пользователя не подменяется молча
    var selectedPlugin: ShaderPlugin? {
        guard let selectedIdentifier else { return plugins.first }
        return plugins.first { $0.identifier == selectedIdentifier }
    }

    func clearStatus() {
        status = nil
    }

    // MARK: - плагины и параметры

    func reload() {
        let directory = shadersDirectory()
        var errors: [PluginError] = []
        do {
            try installBundledPlugins(into: directory)
        } catch {
            errors.append(.installFailed(underlying: error))
        }
        let loaded = loadPlugins(from: directory)
        plugins = loaded.plugins
        loadErrors = errors + loaded.errors

        let live = Set(plugins.map(\.identifier))
        overlay.forgetPipelines(keeping: live)
        settings.forget(outside: live)
    }

    func parameters(for plugin: ShaderPlugin) -> [Float] {
        settings.parameters(for: plugin)
    }

    func setParameter(_ value: Float, at index: Int, for plugin: ShaderPlugin) {
        guard let values = settings.setParameter(value, at: index, for: plugin) else { return }
        if isEnabled, plugin.identifier == selectedPlugin?.identifier {
            overlay.updateParameters(values)
        }
        objectWillChange.send()
    }

    func resetParameters(for plugin: ShaderPlugin) {
        settings.resetParameters(for: plugin)
        if isEnabled, plugin.identifier == selectedPlugin?.identifier {
            overlay.updateParameters(plugin.defaultParameters)
        }
        objectWillChange.send()
    }

    /// вызывается при выходе: значения ползунков лежат в памяти до ближайшей пачки
    func flushParameters() {
        settings.flush()
    }

    func showsCursor(for plugin: ShaderPlugin) -> Bool {
        settings.showsCursor(for: plugin)
    }

    func setShowsCursor(_ value: Bool, for plugin: ShaderPlugin) {
        settings.setShowsCursor(value, for: plugin)
        objectWillChange.send()
        if isEnabled, plugin.identifier == selectedPlugin?.identifier {
            enable()
        }
    }

    // MARK: - включение

    /// при старте эффект восстанавливается молча: запуск по логину не место для
    /// диалога о разрешении, который перекроет вход в систему
    func restoreFromDefaults() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        guard let plugin = selectedPlugin else {
            reportMissingPlugin()
            return
        }
        guard plugin.manifest.level != .capture || hasScreenRecordingAccess() else {
            report(
                title: String(localized: "Effect not restored"),
                message: String(
                    format: String(localized: "\"%@\" needs Screen Recording permission. Turn the effect on to grant it."),
                    plugin.manifest.name
                )
            )
            return
        }
        enable()
    }

    func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    func enable() {
        guard !isStarting else { return }
        guard let plugin = selectedPlugin else {
            reportMissingPlugin()
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
            report(
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
            guard let target = screen(for: selectedDisplayID) else {
                report(
                    title: String(localized: "Display unavailable"),
                    message: String(localized: "The display this effect was set to is no longer connected.")
                )
                return nil
            }
            return target.frame
        }
        guard let id = trackedWindowID else {
            report(
                title: String(localized: "No window selected"),
                message: String(localized: "Pick a window in settings, or turn off window-only mode.")
            )
            return nil
        }
        guard let frame = windowFrame(id) else {
            report(
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
                self.report(
                    title: String(localized: "Effect turned off"),
                    message: String(localized: "The window it followed is closed or minimised.")
                )
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
        if enabled {
            status = nil
        }
    }

    /// пустая папка и исчезнувший пресет это разные беды: во втором случае
    /// шейдеры на месте, просто выбранного среди них больше нет
    private func reportMissingPlugin() {
        guard let identifier = selectedIdentifier, !plugins.isEmpty else {
            report(
                title: String(localized: "No shaders found"),
                message: shadersDirectory().path
            )
            return
        }
        report(
            title: String(localized: "Preset unavailable"),
            message: String(
                format: String(localized: "\"%@\" is no longer in the shaders folder. Pick another preset."),
                identifier
            )
        )
    }

    private func report(title: String, message: String) {
        Log.effects.error("\(title, privacy: .public): \(message, privacy: .public)")
        status = EffectStatus(title: title, message: message)
    }

    @objc private func screensDidChange() {
        displays = availableDisplays()
        guard isEnabled, screen(for: selectedDisplayID) == nil else { return }
        disable()
        report(
            title: String(localized: "Effect turned off"),
            message: String(localized: "The display this effect was set to is no longer connected.")
        )
    }

    private func startCapture(plugin: ShaderPlugin, frame: CGRect) {
        guard ensureScreenRecordingAccess() else {
            disable()
            return
        }
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false }
            do {
                try await overlay.showCapture(
                    plugin: plugin,
                    parameters: parameters(for: plugin),
                    displayID: selectedDisplayID,
                    frame: frame,
                    showsCursor: showsCursor(for: plugin),
                    quality: captureQuality
                ) { [weak self] error in
                    guard let self else { return }
                    self.disable()
                    self.report(
                        title: String(localized: "Screen capture stopped"),
                        message: error.localizedDescription
                    )
                }
                startTrackingIfNeeded()
                setEnabled(true)
            } catch {
                disable()
                report(
                    title: String(localized: "Screen capture failed to start"),
                    message: error.localizedDescription
                )
            }
        }
    }
}
