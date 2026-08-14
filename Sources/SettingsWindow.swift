import AppKit
import KeyboardShortcuts
import Pow
import SwiftUI

/// формат пресета и список изменений живут в репозитории: держать их копию в окне
/// значило бы поддерживать две редакции одного текста
private let shaderFormatURL = URL(
    string: "https://github.com/boundlessend/subvenio-screen/blob/main/DEVELOPMENT.md#writing-a-shader"
)!
private let changelogURL = URL(
    string: "https://github.com/boundlessend/subvenio-screen/blob/main/CHANGELOG.md"
)!

/// вкладки окна настроек. тулбар рисует система, поэтому здесь только имя и символ
enum SettingsTab: String, CaseIterable {
    case effect, presets, display, general

    var title: String {
        switch self {
        case .effect: return String(localized: "Effect")
        case .presets: return String(localized: "Presets")
        case .display: return String(localized: "Display")
        case .general: return String(localized: "General")
        }
    }

    var symbol: String {
        switch self {
        case .effect: return "camera.filters"
        case .presets: return "square.stack"
        case .display: return "macwindow"
        case .general: return "gearshape"
        }
    }
}

/// одно содержимое на вкладку. ширина задаётся снизу, а не жёстко: при увеличенном
/// системном шрифте подписи шире, и фиксированное число обрезало бы их
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
            case .presets: PresetsSettings(effects: effects)
            case .display: DisplaySettings(effects: effects)
            case .general: GeneralSettings(updates: updates)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: Self.width)
    }
}

// MARK: - эффект

struct EffectSettings: View {
    @ObservedObject var effects: EffectController
    /// шейдер выбранного пресета не компилируется: превью знает об этом первым,
    /// потому что собирает пайплайн раньше, чем эффект успевают включить
    @State private var shaderFailure: String?
    /// системная настройка меняется, пока окно открыто, поэтому не читается на месте.
    /// значение по умолчанию не вычисляется здесь: SwiftUI пересоздаёт структуру вью
    /// на каждое обновление, и такой вызов уходил бы в систему десятки раз за перетаскивание
    @State private var reduceMotion = false

    var body: some View {
        Form {
            if effects.plugins.isEmpty {
                Section {
                    Text("No presets available")
                        .foregroundStyle(.secondary)
                    Text("The Presets tab restores the bundled ones.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                mainSection
            }
        }
        .onAppear { reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
                // сначала что пресет делает, потом чего он стоит: имя вроде
                // "Aperture Grille" не отвечает ни на один из этих вопросов
                if let description = plugin.manifest.description?.resolved {
                    Text(description)
                        .font(.callout)
                }
                Text(levelDescription(plugin.manifest.level))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // без этой строки застывший пресет выглядит сломанным, а причина
                // лежит в системных настройках и к приложению отношения не имеет
                if plugin.isAnimated, reduceMotion {
                    Text("This preset animates, and the system \"Reduce Motion\" setting is on, so it stays still.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // ползунков обычно меньше, чем высоты у превью: по центру пустота
                // делится поровну и не выглядит забытым местом
                HStack(alignment: .center, spacing: 20) {
                    parameterControls(for: plugin)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    preview(for: plugin)
                }

                // ошибка компиляции всплывала бы только при попытке включить эффект,
                // а превью собирает тот же шейдер сразу и молчать об этом не должно
                if let shaderFailure {
                    Text(String(
                        format: String(localized: "This preset does not compile: %@"),
                        shaderFailure
                    ))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                }

                if plugin.manifest.parameters?.isEmpty == false {
                    // соседей по кнопке больше нет: управление коллекцией уехало
                    // на свою вкладку, и сброс может называться тем, что он делает
                    Button("Reset to defaults") {
                        effects.resetParameters(for: plugin)
                    }
                }
            } else {
                Text("The selected preset is no longer in the shaders folder. Pick another one.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    /// превью идёт на образце и в своём размере, поэтому частота линий относительно
    /// картинки здесь не та, что достанется экрану: об этом говорит подпись, а не
    /// молчание, иначе расхождение выглядит как ошибка рендеринга
    private func preview(for plugin: ShaderPlugin) -> some View {
        EffectPreview(
            plugin: plugin,
            parameters: effects.parameters(for: plugin),
            failure: $shaderFailure
        )
        .frame(width: 240, height: 138)
        .id(plugin.identifier)
        // смена пресета как смена кадра плёнки: по теме и заодно скрывает
        // паузу на компиляцию нового шейдера
        .transition(.movingParts.filmExposure)
        .accessibilityElement()
        .accessibilityLabel(String(
            format: String(localized: "Preview of \"%@\" on the bundled sample picture"),
            plugin.manifest.name
        ))
        .help("The preview runs on a bundled picture at its own size, so a pattern this fine covers fewer pixels here than it will on the screen.")
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
                    parameterRow(parameter, index: index, value: values[index], plugin: plugin)
                }
            }
        }
    }

    private func parameterRow(
        _ parameter: ShaderParameter,
        index: Int,
        value: Float,
        plugin: ShaderPlugin
    ) -> some View {
        let title = parameter.title?.resolved ?? parameterTitle(parameter.name)
        let binding = Binding(
            get: { Double(value) },
            set: { new in
                // поле принимает что угодно, а диапазон задал автор пресета
                let clamped = min(max(Float(new), parameter.min), parameter.max)
                effects.setParameter(clamped, at: index, for: plugin)
            }
        )
        return HStack(spacing: 10) {
            Text(title)
                .frame(width: 118, alignment: .leading)
                .lineLimit(1)
            Slider(value: binding, in: Double(parameter.min)...Double(parameter.max))
                // подпись рядом это отдельная вьюха, и VoiceOver её со ползунком
                // не связывает: без этого он читает голое число
                .accessibilityLabel(title)
            // поле, а не подпись: описания пресетов называют точные значения
            // вроде оттенка 0,36, а мышью в них попасть нечем.
            // формат числа берёт разделитель из локали, а не из POSIX
            TextField(
                title,
                value: binding,
                format: .number.precision(.fractionLength(fractionLength(of: parameter)))
            )
            .labelsHidden()
            // рамка, а не голое число: без неё поле неотличимо от подписи,
            // и то, что в него можно печатать, не видно
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 62)
        }
    }

    /// знаков после запятой столько, сколько несёт диапазон: размер ячейки от 2 до 16
    /// показывать как «6,00» незачем, а оттенок от 0 до 1 без сотых не настроить
    private func fractionLength(of parameter: ShaderParameter) -> Int {
        let span = parameter.max - parameter.min
        if span >= 10 { return 0 }
        return span >= 2 ? 1 : 2
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

    /// цена пресета и то, что от него ждать. про пропажу на переключении пространств
    /// сказано здесь же: молча она читается как сбой рендеринга, а причина в компоновщике
    private func levelDescription(_ level: RenderLevel) -> String {
        switch level {
        case .gammaLUT:
            return String(localized: """
            Level 1: gamma table. Covers the cursor, the menu bar and the Dock, \
            costs nothing and stays on while you switch spaces.
            """)
        case .overlay:
            return String(localized: """
            Level 2: a transparent layer above the screen. Needs no permissions, \
            and drops for about a second when you switch spaces.
            """)
        case .capture:
            return String(localized: """
            Level 3: reads the picture on screen. Needs Screen Recording permission, \
            and drops for about a second when you switch spaces.
            """)
        }
    }
}

// MARK: - пресеты

/// коллекция пресетов целиком: папка, заготовка, возврат встроенных и то, что
/// не загрузилось. на вкладке эффекта эти кнопки стояли рядом с настройкой одного
/// пресета и читались как действия над ним
struct PresetsSettings: View {
    @ObservedObject var effects: EffectController
    @State private var isConfirmingRestore = false

    var body: some View {
        Form {
            Section {
                Text("A preset is a folder with a manifest and a Metal shader. Save a file and the menu updates itself, with no restart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Open shaders folder") {
                        NSWorkspace.shared.open(shadersDirectory())
                    }
                    Button("New preset from template") { newPreset() }
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

                // «открыть папку» без описания формата означает, что человек обязан
                // помнить манифест и сигнатуру фрагментной функции наизусть
                Link("How to write a preset", destination: shaderFormatURL)
                    .font(.callout)
            }

            if !effects.loadErrors.isEmpty {
                Section("Failed to load") {
                    ForEach(effects.loadErrors.indices, id: \.self) { index in
                        Text(effects.loadErrors[index].localizedDescription)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// заготовка появляется в папке и сразу показывается в Finder: наблюдатель за папкой
    /// добавит её в меню сам, а человеку остаётся открыть shader.metal
    private func newPreset() {
        do {
            let created = try createPresetFromTemplate(in: shadersDirectory())
            NSWorkspace.shared.activateFileViewerSelecting([created])
        } catch {
            showAlert(
                title: String(localized: "Could not create the preset"),
                message: error.localizedDescription
            )
        }
    }
}

// MARK: - дисплей

/// где лежит эффект и чего стоит его чтение экрана: один вопрос, поэтому одна вкладка
struct DisplaySettings: View {
    @ObservedObject var effects: EffectController
    /// список окон живой и меняется постоянно, поэтому обновляется сам, пока вкладка видна.
    /// пустой по умолчанию: перебор всех окон системы на каждое пересоздание структуры
    /// вью стоил бы дороже самого режима
    @State private var windows: [TrackedWindow] = []

    private let windowRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            // первая секция без заголовка, как в системных настройках: главный вопрос
            // вкладки называет её заголовок окна, а подписан только второй
            Section {
                Picker("Display:", selection: $effects.selectedDisplayID) {
                    // отключённый монитор пропадает из списка, а выбор на нём остаётся:
                    // без этой строки Picker показывал бы пустое место
                    if !effects.displays.contains(where: { $0.id == effects.selectedDisplayID }) {
                        Text("Disconnected display").tag(effects.selectedDisplayID)
                    }
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
                            if let tracked = effects.trackedWindowID,
                               !windows.contains(where: { $0.id == tracked }) {
                                Text("Window is closed").tag(CGWindowID?.some(tracked))
                            }
                            ForEach(windows, id: \.id) { window in
                                Text(window.title).tag(CGWindowID?.some(window.id))
                            }
                        }
                        Button("Refresh") { windows = availableWindows() }
                    }
                    .onAppear { windows = availableWindows() }
                    .onReceive(windowRefresh) { _ in windows = availableWindows() }
                }
            }

            Section("Capture") {
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
    @ObservedObject var updates: UpdateController
    /// регистрация автозапуска спрашивается у системы через XPC, поэтому не в значении
    /// по умолчанию: оно вычисляется на каждое пересоздание структуры вью
    @State private var launchAtLogin = false

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

            updateSection
        }
        .onAppear { launchAtLogin = isLaunchAtLoginEnabled() }
    }

    /// обновления идут через страницу релизов GitHub: приложение только сообщает
    /// о новой версии и открывает браузер, ничего не скачивая само
    @ViewBuilder
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

            // что именно изменится, видно до загрузки, а не только со страницы релиза
            Link("What changed between versions", destination: changelogURL)
                .font(.callout)
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
