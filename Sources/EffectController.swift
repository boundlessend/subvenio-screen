import AppKit
import Combine

/// что предложить человеку кроме «понятно»: путь к папке в тексте ошибки читается
/// как часть поломки, а кнопка ведёт туда, где её можно исправить
enum EffectRecovery {
    case openShadersFolder
}

/// проблема, о которой надо сказать пользователю. фоновое приложение без окна не имеет
/// права перекрывать чужую работу модальным диалогом, поэтому статус живёт в меню-баре
struct EffectStatus {
    let title: String
    let message: String
    let recovery: EffectRecovery?
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
    private static let windowModeKey = "windowMode"

    @Published private(set) var plugins: [ShaderPlugin] = []
    @Published private(set) var loadErrors: [PluginError] = []
    @Published private(set) var isEnabled = false
    /// запуск уровня 3 асинхронный, и пока он идёт, isEnabled ещё false.
    /// публикуется, потому что по нему рисуется переключатель в настройках
    @Published private(set) var isStarting = false
    @Published private(set) var status: EffectStatus?

    /// эффект на экране или как раз туда едет. смена пресета в момент подъёма
    /// потока захвата иначе терялась бы: didSet смотрел бы на ещё выключенный эффект
    var isActive: Bool { isEnabled || isStarting }
    /// список экранов меняется редко, а читается на каждый перерасчёт настроек
    @Published private(set) var displays: [DisplayChoice] = availableDisplays()

    @Published var selectedIdentifier: String? {
        didSet {
            guard selectedIdentifier != oldValue else { return }
            UserDefaults.standard.set(selectedIdentifier, forKey: Self.selectedShaderKey)
            if isActive {
                enable()
            }
        }
    }

    /// на какой монитор кладём эффект. один активный эффект на один дисплей:
    /// независимые пресеты на нескольких мониторах сразу потребуют по контроллеру на дисплей
    @Published var selectedDisplayID: CGDirectDisplayID {
        didSet {
            guard selectedDisplayID != oldValue else { return }
            UserDefaults.standard.set(Int(selectedDisplayID), forKey: Self.selectedDisplayKey)
            if isActive {
                enable()
            } else if waitingForDisplay, screen(for: selectedDisplayID) != nil {
                // эффект сняли вместе с пропавшим монитором, и человек выбрал другой:
                // это и есть просьба вернуть его, ждать ещё одного события о дисплеях незачем
                waitingForDisplay = false
                clearStatus()
                enable()
            }
        }
    }

    /// эффект только в области выбранного окна вместо всего дисплея
    @Published var windowModeEnabled: Bool {
        didSet {
            guard windowModeEnabled != oldValue else { return }
            UserDefaults.standard.set(windowModeEnabled, forKey: Self.windowModeKey)
            if isActive {
                enable()
            } else {
                tracker = nil
            }
        }
    }

    @Published var trackedWindowID: CGWindowID? {
        didSet {
            guard trackedWindowID != oldValue, isActive, windowModeEnabled else { return }
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
            if isActive, selectedPlugin?.manifest.level == .capture {
                enable()
            }
        }
    }

    private let overlay = OverlayController()
    private let gamma = GammaController()
    private let settings = PluginSettings()
    private var tracker: WindowTracker?
    private var watcher: PluginWatcher?
    /// номер поколения включения: пока асинхронный старт уровня 3 идёт, эффект могли
    /// выключить. состояние «включено» с чужим номером означало бы работу без окна
    private var enableGeneration = 0
    /// неудача установки встроенных пресетов: она случается один раз за запуск,
    /// а список ошибок пересобирается на каждое чтение папки
    private var installError: PluginError?
    /// эффект сняли, потому что дисплей отключили: его вернут, когда монитор придёт назад
    private var waitingForDisplay = false

    init() {
        let defaults = UserDefaults.standard
        let storedDisplay = defaults.integer(forKey: Self.selectedDisplayKey)
        selectedDisplayID = storedDisplay > 0 ? CGDirectDisplayID(storedDisplay) : CGMainDisplayID()
        selectedIdentifier = defaults.string(forKey: Self.selectedShaderKey)
        windowModeEnabled = defaults.bool(forKey: Self.windowModeKey)
        let storedScale = defaults.double(forKey: Self.captureScaleKey)
        captureQuality = CaptureQuality(
            scale: storedScale > 0 ? storedScale : 1,
            frameRateCap: defaults.integer(forKey: Self.captureFrameRateKey)
        )

        installBundled()
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
        guard let selectedIdentifier else {
            // на свежей установке выбора ещё нет, и он достаётся алфавиту. пусть
            // достанется самому дешёвому уровню: иначе первое же нажатие хоткея
            // на новой машине упирается в запрос разрешения на запись экрана
            return plugins.first { $0.manifest.level == .gammaLUT } ?? plugins.first
        }
        return plugins.first { $0.identifier == selectedIdentifier }
    }

    func clearStatus() {
        status = nil
    }

    // MARK: - плагины и параметры

    /// встроенные пресеты ставятся один раз за запуск. делать это на каждое чтение папки
    /// значило бы писать в неё в ответ на чужую запись: наблюдатель разбудил бы себя сам
    private func installBundled() {
        do {
            try installBundledPlugins(into: shadersDirectory())
            installError = nil
        } catch {
            installError = .installFailed(underlying: error)
        }
    }

    func reload() {
        // редакция выбранного пресета до перечитывания папки: по ней видно, изменил ли
        // человек шейдер, который прямо сейчас лежит на экране
        let previous = selectedPlugin
        let loaded = loadPlugins(from: shadersDirectory())
        plugins = loaded.plugins
        loadErrors = [installError].compactMap { $0 } + loaded.errors

        let live = Set(plugins.map(\.identifier))
        overlay.forgetPipelines(keeping: live)
        // настройки чистятся только по целиком прочитанной папке: пустой список или
        // ошибка загрузки означают сбой чтения, а не удалённые пресеты, и уборка
        // по такому списку стёрла бы значения ползунков у всех
        if !plugins.isEmpty, loadErrors.isEmpty {
            settings.forget(outside: live)
        }

        // шейдер переписали на диске: пайплайн собран при включении и сам новую
        // редакцию не подхватит, а превью в настройках уже показывает её
        if isEnabled, let previous, let current = selectedPlugin, current != previous {
            Log.plugins.info(
                "preset changed on disk, restarting: \(current.identifier, privacy: .public)"
            )
            enable()
        }
    }

    /// встроенные пресеты обратно в исходный вид: единственный путь починить тот,
    /// который правили руками и сломали
    func restoreBundled() {
        do {
            try restoreBundledPlugins(into: shadersDirectory())
            reload()
        } catch {
            report(
                title: String(localized: "Presets could not be restored"),
                message: error.localizedDescription
            )
        }
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
        // нажатие во время асинхронного старта уровня 3 отменяет его, а не пропадает:
        // человек, нажавший второй раз, передумал или решил, что не сработало,
        // и молчание в ответ - худший из возможных ответов
        if isActive {
            // выключил человек, а не пропавший монитор: ждать возвращения нечего
            waitingForDisplay = false
            disable()
        } else {
            enable()
        }
    }

    func enable() {
        waitingForDisplay = false
        guard let plugin = selectedPlugin else {
            reportMissingPlugin()
            return
        }

        enableGeneration += 1
        // старт, который сейчас идёт, поднимает уже не тот эффект, о котором просят:
        // свой флаг он больше не сбросит, потому что уедет по чужому поколению
        isStarting = false
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
        enableGeneration += 1
        isStarting = false
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
        // обе беды чинятся в одной и той же папке, поэтому обе ведут туда кнопкой,
        // а не показывают путь строкой посреди текста ошибки
        guard let identifier = selectedIdentifier, !plugins.isEmpty else {
            setStatus(
                title: String(localized: "No shaders found"),
                message: String(localized: "The shaders folder holds no presets. Restore the bundled ones in settings, or put a preset in yourself."),
                recovery: .openShadersFolder
            )
            return
        }
        setStatus(
            title: String(localized: "Preset unavailable"),
            message: String(
                format: String(localized: "\"%@\" is no longer in the shaders folder. Pick another preset."),
                identifier
            ),
            recovery: .openShadersFolder
        )
    }

    private func report(title: String, message: String) {
        setStatus(title: title, message: message, recovery: nil)
    }

    private func setStatus(title: String, message: String, recovery: EffectRecovery?) {
        Log.effects.error("\(title, privacy: .public): \(message, privacy: .public)")
        status = EffectStatus(title: title, message: message, recovery: recovery)
    }

    @objc private func screensDidChange() {
        displays = availableDisplays()
        let target = screen(for: selectedDisplayID)

        if isEnabled, target == nil {
            disable()
            // выключили не по просьбе человека, а потому что рисовать стало некуда
            waitingForDisplay = true
            report(
                title: String(localized: "Effect turned off"),
                message: String(localized: "The display this effect was set to is no longer connected.")
            )
            return
        }
        // монитор вернулся: отстыкованный ноутбук не повод заставлять человека
        // включать эффект заново каждый раз
        guard waitingForDisplay, target != nil else { return }
        waitingForDisplay = false
        clearStatus()
        enable()
    }

    private func startCapture(plugin: ShaderPlugin, frame: CGRect) {
        guard ensureScreenRecordingAccess(for: plugin.manifest.name) else {
            disable()
            return
        }
        isStarting = true
        let generation = enableGeneration
        Task { @MainActor in
            // флаг сбрасывает тот старт, который его поставил: пришедший следом
            // enable или disable уже погасил его сам и мог поднять свой
            defer { if generation == enableGeneration { isStarting = false } }
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
                // эффект выключили или переключили, пока поток поднимался: оверлей уже снят,
                // и объявлять его включённым было бы враньём
                guard generation == enableGeneration else { return }
                startTrackingIfNeeded()
                setEnabled(true)
            } catch {
                guard generation == enableGeneration else { return }
                disable()
                report(
                    title: String(localized: "Screen capture failed to start"),
                    message: error.localizedDescription
                )
            }
        }
    }
}
