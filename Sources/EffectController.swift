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

    private let overlay = OverlayController()
    private let gamma = GammaController()

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
            showAlert(title: "Нет ни одного шейдера", message: shadersDirectory().path)
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
                    displayID: selectedDisplayID
                )
                setEnabled(true)
            case .capture:
                gamma.deactivate()
                startCapture(plugin: plugin)
            }
        } catch {
            disable()
            showAlert(title: "Эффект не запустился", message: error.localizedDescription)
        }
    }

    func disable() {
        overlay.hide()
        gamma.deactivate()
        setEnabled(false)
    }

    /// вызывается при выходе: иначе после закрытия экран остался бы перекрашенным
    func restoreGamma() {
        gamma.deactivate()
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    private func startCapture(plugin: ShaderPlugin) {
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
                    showsCursor: showsCursor(for: plugin)
                ) { [weak self] error in
                    DispatchQueue.main.async {
                        self?.disable()
                        showAlert(
                            title: "Захват экрана остановлен",
                            message: error.localizedDescription
                        )
                    }
                }
                setEnabled(true)
            } catch {
                disable()
                showAlert(title: "Захват экрана не запустился", message: error.localizedDescription)
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
    explanation.messageText = "Этому эффекту нужно разрешение Screen Recording"
    explanation.informativeText = """
    Гамма-таблица умеет менять каналы по отдельности, но не смешивать их, \
    поэтому честный чёрно-белый обязан читать изображение экрана.

    Кадры живут только в памяти до вывода на экран: приложение ничего не пишет \
    на диск и никуда не передаёт.

    Дальше откроется системный диалог, где надо разрешить запись экрана.
    """
    explanation.addButton(withTitle: "Продолжить")
    explanation.addButton(withTitle: "Отмена")
    guard explanation.runModal() == .alertFirstButtonReturn else { return false }

    if requestScreenRecordingAccess() {
        return true
    }

    // системный диалог показывается один раз за установку, дальше только руками
    NSApp.activate(ignoringOtherApps: true)
    let denied = NSAlert()
    denied.messageText = "Разрешение не выдано"
    denied.informativeText = "Откройте «Конфиденциальность и безопасность» → «Запись экрана» и включите ScreenFilter."
    denied.addButton(withTitle: "Открыть настройки")
    denied.addButton(withTitle: "Отмена")
    if denied.runModal() == .alertFirstButtonReturn {
        openScreenRecordingSettings()
    }
    return false
}
