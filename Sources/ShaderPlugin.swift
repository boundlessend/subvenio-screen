import CryptoKit
import Foundation

/// уровень рендеринга из PLAN.md: 1 гамма-LUT, 2 alpha-оверлей, 3 захват экрана
enum RenderLevel: Int, Decodable, CaseIterable {
    case gammaLUT = 1
    case overlay = 2
    case capture = 3

    /// заголовок группы пресетов в меню и в списке настроек. говорит не про технику,
    /// а про то, что человек заплатит: ничего, один слой поверх экрана или
    /// разрешение на чтение экрана
    var groupTitle: String {
        switch self {
        case .gammaLUT: return String(localized: "Free")
        case .overlay: return String(localized: "One drawn layer")
        case .capture: return String(localized: "Reads the screen")
        }
    }
}

/// текст пресета, который читает человек: либо одна строка, либо строка на язык.
/// {"en": ..., "ru": ...} выбирается по языку интерфейса, простая строка остаётся
/// как есть - чужому пресету незачем знать про наши локали
enum LocalizedText: Decodable, Equatable {
    case plain(String)
    case byLanguage([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
            return
        }
        self = .byLanguage(try container.decode([String: String].self))
    }

    /// nil означает, что на языке интерфейса текста нет: подставлять чужой язык хуже,
    /// чем обойтись без строки или собрать её из имени параметра
    var resolved: String? {
        switch self {
        case let .plain(text):
            return text
        case let .byLanguage(texts):
            for code in Bundle.main.preferredLocalizations {
                if let text = texts[code] {
                    return text
                }
            }
            return texts["en"]
        }
    }
}

struct ShaderParameter: Decodable, Equatable {
    let name: String
    /// подпись ползунка. без неё окно соберёт её из имени: grainStrength -> Grain Strength
    let title: LocalizedText?
    let min: Float
    let max: Float
    let `default`: Float
}

/// поканальное преобразование для уровня 1: смешивать каналы гамма-таблица не умеет,
/// поэтому здесь только тинт, гамма, инверсия и клиппинг
struct GammaSettings: Decodable, Equatable {
    let tint: [Float]
    let gamma: Float
    let invert: Bool
    let blackPoint: Float
    let whitePoint: Float
}

struct ShaderManifest: Decodable, Equatable {
    let name: String
    /// одна фраза о том, что пресет делает: имя вроде "Halation" не говорит ничего.
    /// показывается под превью и подсказкой в меню
    let description: LocalizedText?
    let level: RenderLevel
    let animated: Bool?
    /// имя символа SF Symbols для меню. пресет описывает себя сам, как и своим именем;
    /// без него меню возьмёт символ уровня рендеринга
    let icon: String?
    let parameters: [ShaderParameter]?
    let gamma: GammaSettings?
}

/// уровень 1 работает без шейдера, уровень 2 без гамма-таблиц: разные наборы данных,
/// поэтому не опциональные поля, а два случая
enum PluginKind: Equatable {
    case gamma(GammaSettings)
    case overlay(source: String)
    case capture(source: String)
}

/// равенство по содержимому, а не по идентификатору: правку шейдера на диске
/// видно только так, и по ней работающий эффект перезапускается на новую редакцию
struct ShaderPlugin: Equatable {
    let manifest: ShaderManifest
    let kind: PluginKind
    /// имя папки, используется как стабильный идентификатор в UserDefaults
    let identifier: String

    var isAnimated: Bool { manifest.animated ?? false }
    var defaultParameters: [Float] { (manifest.parameters ?? []).map(\.default) }
}

enum PluginError: LocalizedError {
    case installFailed(underlying: Error)
    case manifestUnreadable(plugin: String, underlying: Error)
    case sourceMissing(plugin: String)
    case gammaSettingsMissing(plugin: String)
    case invalidGammaTint(plugin: String, count: Int)
    case unsupportedLevel(plugin: String, level: RenderLevel)
    case tooManyParameters(plugin: String, count: Int)
    case invalidParameterName(plugin: String, name: String)
    case invalidParameterRange(plugin: String, parameter: String)
    case invalidParameterDefault(plugin: String, parameter: String)
    case fragmentFunctionMissing(plugin: String)
    case compilationFailed(plugin: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .installFailed(underlying):
            return String(
                format: String(localized: "bundled presets could not be installed - %@"),
                underlying.localizedDescription
            )
        case let .manifestUnreadable(plugin, underlying):
            return String(
                format: String(localized: "%@: manifest is unreadable - %@"),
                plugin, underlying.localizedDescription
            )
        case let .sourceMissing(plugin):
            return String(
                format: String(localized: "%@: there is no shader.metal next to the manifest"),
                plugin
            )
        case let .gammaSettingsMissing(plugin):
            return String(
                format: String(localized: "%@: level 1 needs a gamma section in the manifest"),
                plugin
            )
        case let .invalidGammaTint(plugin, count):
            return String(
                format: String(localized: "%@: tint must hold 3 values, not %lld"),
                plugin, count
            )
        case let .unsupportedLevel(plugin, level):
            return String(
                format: String(localized: "%@: render level %lld is not supported yet"),
                plugin, level.rawValue
            )
        case let .tooManyParameters(plugin, count):
            return String(
                format: String(localized: "%@: %lld parameters, the maximum is %lld"),
                plugin, count, maxShaderParameters
            )
        case let .invalidParameterName(plugin, name):
            return String(
                format: String(localized: "%@: \"%@\" is not a valid parameter name, letters, digits and _ only"),
                plugin, name
            )
        case let .invalidParameterRange(plugin, parameter):
            return String(
                format: String(localized: "%@: parameter \"%@\" has min greater than or equal to max"),
                plugin, parameter
            )
        case let .invalidParameterDefault(plugin, parameter):
            return String(
                format: String(localized: "%@: the default of parameter \"%@\" lies outside its range"),
                plugin, parameter
            )
        case let .fragmentFunctionMissing(plugin):
            return String(
                format: String(localized: "%@: the shader declares no overlay_fragment function"),
                plugin
            )
        case let .compilationFailed(plugin, underlying):
            return String(
                format: String(localized: "%@: shader does not compile - %@"),
                plugin, underlying.localizedDescription
            )
        }
    }

    var pluginName: String {
        switch self {
        case .installFailed:
            return String(localized: "Bundled presets")
        case let .manifestUnreadable(plugin, _),
             let .sourceMissing(plugin),
             let .gammaSettingsMissing(plugin),
             let .invalidGammaTint(plugin, _),
             let .unsupportedLevel(plugin, _),
             let .tooManyParameters(plugin, _),
             let .invalidParameterName(plugin, _),
             let .invalidParameterRange(plugin, _),
             let .invalidParameterDefault(plugin, _),
             let .fragmentFunctionMissing(plugin),
             let .compilationFailed(plugin, _):
            return plugin
        }
    }
}

/// ~/Library/Application Support/SubvenioScreen/Shaders
func shadersDirectory() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("SubvenioScreen/Shaders", isDirectory: true)
}

/// отпечаток содержимого пресета: имена файлов и их байты по порядку.
/// по нему видно, трогал ли пользователь то, что мы положили
func pluginDigest(_ directory: URL) -> String? {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { return nil }

    var hasher = SHA256()
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let data = try? Data(contentsOf: file) else { return nil }
        hasher.update(data: Data(file.lastPathComponent.utf8))
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func installedDigestKey(_ identifier: String) -> String {
    "bundled.\(identifier).digest"
}

/// копирует недостающие встроенные пресеты и обновляет те, которых пользователь не касался.
/// без обновления исправленный шейдер новой версии не доезжал бы до тех, у кого папка уже
/// есть; правки узнаются по отпечатку, записанному в момент установки, и остаются на месте
func installBundledPlugins(
    into directory: URL,
    from bundle: Bundle = .main,
    defaults: UserDefaults = .standard
) throws {
    guard let bundled = bundle.url(forResource: "Shaders", withExtension: nil) else {
        throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let entries = try FileManager.default.contentsOfDirectory(
        at: bundled,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    for entry in entries {
        let identifier = entry.lastPathComponent
        let destination = directory.appendingPathComponent(identifier)
        let key = installedDigestKey(identifier)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            // отпечаток есть, а папки нет: пресет удалили руками, и это выбор,
            // а не пропажа. класть его обратно на каждый запуск значило бы спорить
            // с человеком; вернуть все встроенные умеет кнопка в настройках
            guard defaults.string(forKey: key) == nil else { continue }
            try FileManager.default.copyItem(at: entry, to: destination)
            defaults.set(pluginDigest(destination), forKey: key)
            continue
        }

        let onDisk = pluginDigest(destination)
        guard let installed = defaults.string(forKey: key) else {
            // пресет приехал версией приложения, которая отпечатков ещё не вела:
            // считаем его правленым и запоминаем как есть, чтобы дальше механизм работал
            defaults.set(onDisk, forKey: key)
            continue
        }
        // пресет правил пользователь, либо он уже совпадает со встроенным
        guard onDisk == installed, pluginDigest(entry) != installed else { continue }

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: entry, to: destination)
        defaults.set(pluginDigest(destination), forKey: key)
        Log.plugins.info("bundled preset updated: \(identifier, privacy: .public)")
    }
}

/// возвращает встроенные пресеты к виду, в котором они приехали с приложением.
/// вызывается только по явной просьбе: правки пользователя здесь теряются
func restoreBundledPlugins(
    into directory: URL,
    from bundle: Bundle = .main,
    defaults: UserDefaults = .standard
) throws {
    guard let bundled = bundle.url(forResource: "Shaders", withExtension: nil) else {
        throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let entries = try FileManager.default.contentsOfDirectory(
        at: bundled,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    for entry in entries {
        let destination = directory.appendingPathComponent(entry.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: entry, to: destination)
        defaults.set(
            pluginDigest(destination),
            forKey: installedDigestKey(entry.lastPathComponent)
        )
    }
}

/// сканирует папку с плагинами; битые плагины возвращаются ошибками, а не выбрасываются молча
func loadPlugins(from directory: URL) -> (plugins: [ShaderPlugin], errors: [PluginError]) {
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []

    var plugins: [ShaderPlugin] = []
    var errors: [PluginError] = []

    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let manifestURL = entry.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }

        do {
            let manifest = try JSONDecoder().decode(
                ShaderManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            switch pluginKind(manifest: manifest, directory: entry) {
            case let .success(kind):
                plugins.append(
                    ShaderPlugin(manifest: manifest, kind: kind, identifier: entry.lastPathComponent)
                )
            case let .failure(error):
                errors.append(error)
            }
        } catch {
            errors.append(.manifestUnreadable(plugin: entry.lastPathComponent, underlying: error))
        }
    }

    // порядок в списке задаёт видимое имя, а не имя папки: "Phosphor Terminal"
    // лежит в AmberTerminal и без этого встаёт первым ни по какому видимому признаку.
    // localizedStandardCompare ставит "1-bit Dither" перед буквами, как это делает Finder
    let sorted = plugins.sorted {
        $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
    }
    return (sorted, errors)
}

private func pluginKind(
    manifest: ShaderManifest,
    directory: URL
) -> Result<PluginKind, PluginError> {
    switch manifest.level {
    case .gammaLUT:
        guard let gamma = manifest.gamma else {
            return .failure(.gammaSettingsMissing(plugin: manifest.name))
        }
        guard gamma.tint.count == 3 else {
            return .failure(.invalidGammaTint(plugin: manifest.name, count: gamma.tint.count))
        }
        return .success(.gamma(gamma))

    case .overlay, .capture:
        let sourceURL = directory.appendingPathComponent("shader.metal")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return .failure(.sourceMissing(plugin: manifest.name))
        }
        let parameters = manifest.parameters ?? []
        guard parameters.count <= maxShaderParameters else {
            return .failure(.tooManyParameters(plugin: manifest.name, count: parameters.count))
        }
        if let error = validate(parameters, of: manifest.name) {
            return .failure(error)
        }
        return .success(
            manifest.level == .overlay ? .overlay(source: source) : .capture(source: source)
        )
    }
}

/// манифест пишет человек, поэтому это граница доверия: имя уходит в #define шейдера,
/// а границы уходят в диапазон слайдера, который падает при min больше max
private func validate(_ parameters: [ShaderParameter], of plugin: String) -> PluginError? {
    for parameter in parameters {
        guard isIdentifier(parameter.name) else {
            return .invalidParameterName(plugin: plugin, name: parameter.name)
        }
        guard parameter.min < parameter.max else {
            return .invalidParameterRange(plugin: plugin, parameter: parameter.name)
        }
        guard (parameter.min...parameter.max).contains(parameter.default) else {
            return .invalidParameterDefault(plugin: plugin, parameter: parameter.name)
        }
    }
    return nil
}

/// идентификатор C: буквы ASCII, цифры и подчёркивание, первый символ не цифра
private func isIdentifier(_ name: String) -> Bool {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    guard let first = name.first, !first.isNumber else { return false }
    return name.allSatisfy(allowed.contains)
}
