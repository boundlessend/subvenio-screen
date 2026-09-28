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

/// куда ложится эффект: рамка и экран, которому она принадлежит. на весь дисплей
/// это выбранный монитор, в оконном режиме тот, на котором сейчас лежит окно
struct EffectTarget {
    let frame: CGRect
    let screen: NSScreen

    var displayID: CGDirectDisplayID { screen.displayID }
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
    /// экран, на котором эффект лежит сейчас. в оконном режиме он задаётся окном,
    /// а не выбором в настройках, и по нему видно, что окно уехало на другой монитор
    private var activeDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private let fullScreen = FullScreenVideoWatch()

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
        fullScreen.onChange = { [weak self] in self?.enable() }
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

    /// следующий по списку, по кругу. список тот же, что в меню и в настройках,
    /// поэтому порядок перебора совпадает с тем, что человек там видит
    func selectNextPlugin() {
        guard !plugins.isEmpty else {
            reportMissingPlugin()
            return
        }
        let current = selectedPlugin.flatMap { plugin in
            plugins.firstIndex { $0.identifier == plugin.identifier }
        }
        let next = current.map { ($0 + 1) % plugins.count } ?? 0
        selectedIdentifier = plugins[next].identifier
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
    /// который правили руками и сломали.
    /// ошибка уходит наверх, а не в меню-бар: кнопку нажимают в окне настроек,
    /// и ответ на нажатие человек ждёт там же
    func restoreBundled() throws {
        try restoreBundledPlugins(into: shadersDirectory())
        reload()
    }

    /// чужой пресет, брошенный на окно настроек
    func installDropped(_ folder: URL) throws {
        try installDroppedPlugin(folder, into: shadersDirectory())
        reload()
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
        // зонд полного экрана при запуске ещё не осел, и включение сразу мелькнуло бы
        // эффектом поверх уже открытого полноэкранного видео. ждать приходится время,
        // а не сигнал: на обычном рабочем столе первый ответ зонда уже окончательный
        let generation = enableGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + FullScreenProbe.settleTime) { [weak self] in
            MainActor.assumeIsolated {
                // за это время человек мог сам нажать хоткей: его решение главнее
                guard let self, generation == self.enableGeneration else { return }
                self.enable()
            }
        }
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
        guard let target = target(for: plugin) else {
            disable()
            return
        }
        activeDisplayID = target.displayID

        // фильм в полном экране это чужая картинка: эффект остаётся включённым,
        // но уходит с экрана до выхода из полного экрана
        if fullScreen.yieldsToVideo(on: target.screen) {
            Log.effects.info("full screen video on the display, the effect waits for it to end")
            overlay.hide()
            gamma.deactivate()
            setEnabled(true)
            return
        }

        do {
            switch plugin.kind {
            case let .gamma(settings):
                overlay.hide()
                try gamma.activate(settings, displayID: target.displayID)
                setEnabled(true)
            case .overlay:
                gamma.deactivate()
                try overlay.show(
                    plugin: plugin,
                    parameters: parameters(for: plugin),
                    displayID: target.displayID,
                    frame: target.frame
                )
                startTrackingIfNeeded()
                setEnabled(true)
            case .capture:
                gamma.deactivate()
                startCapture(plugin: plugin, frame: target.frame, displayID: target.displayID)
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
        fullScreen.stop()
        tracker = nil
        overlay.hide()
        gamma.deactivate()
        setEnabled(false)
    }

    /// область эффекта: рамка выбранного окна или весь дисплей.
    /// уровень 1 живёт в scanout целиком, областью его не ограничить
    private func target(for plugin: ShaderPlugin) -> EffectTarget? {
        guard windowModeEnabled, plugin.manifest.level != .gammaLUT else {
            guard let target = screen(for: selectedDisplayID) else {
                // выключились не по просьбе человека: монитор вернётся, вернём и эффект.
                // без флага эффект не поднимался после запуска с отстыкованным доком
                waitingForDisplay = true
                report(
                    title: String(localized: "Display unavailable"),
                    message: String(localized: "The display this effect was set to is no longer connected.")
                )
                return nil
            }
            return EffectTarget(frame: target.frame, screen: target)
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
        // дисплей задаёт само окно, а не Picker в настройках: окно живёт там, где
        // человек его оставил, и доли кадра обязаны считаться от того же экрана,
        // с которого идёт захват
        guard let target = screen(containing: frame) else {
            report(
                title: String(localized: "Window unavailable"),
                message: String(localized: "The selected window is closed or minimised.")
            )
            return nil
        }
        return EffectTarget(frame: frame, screen: target)
    }

    private func startTrackingIfNeeded() {
        guard windowModeEnabled, let id = trackedWindowID else { return }
        tracker = WindowTracker(windowID: id) { [weak self] frame in
            guard let self else { return }
            guard let frame else {
                // окно свернули или закрыли: эффект снимается, приложение остаётся работать
                self.disable()
                self.report(
                    title: String(localized: "Effect turned off"),
                    message: String(localized: "The window it followed is closed or minimised.")
                )
                return
            }
            // окно уехало на другой монитор: одним переносом рамки тут не обойтись,
            // потому что доли кадра и поток захвата привязаны к прежнему экрану
            guard screen(containing: frame)?.displayID == self.activeDisplayID else {
                self.enable()
                return
            }
            self.overlay.updateFrame(frame)
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

        // пропал экран, на котором эффект лежит сейчас: в оконном режиме это не тот,
        // что выбран в настройках, а тот, на котором стоит отслеживаемое окно
        if isEnabled, screen(for: activeDisplayID) == nil {
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
        guard waitingForDisplay, screen(for: selectedDisplayID) != nil else { return }
        waitingForDisplay = false
        clearStatus()
        enable()
    }

    private func startCapture(plugin: ShaderPlugin, frame: CGRect, displayID: CGDirectDisplayID) {
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
                    displayID: displayID,
                    frame: frame,
                    showsCursor: showsCursor(for: plugin),
                    quality: captureQuality
                ) { [weak self] error in
                    guard let self else { return }
                    self.disable()
                    // поток мог упасть потому, что монитор под ним отключили: это не
                    // выбор человека, и вернувшийся монитор должен вернуть эффект сам
                    self.waitingForDisplay = screen(for: displayID) == nil
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
