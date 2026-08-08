import Foundation

/// уровень рендеринга из PLAN.md: 1 гамма-LUT, 2 alpha-оверлей, 3 захват экрана
enum RenderLevel: Int, Decodable {
    case gammaLUT = 1
    case overlay = 2
    case capture = 3
}

struct ShaderParameter: Decodable {
    let name: String
    let min: Float
    let max: Float
    let `default`: Float
}

/// поканальное преобразование для уровня 1: смешивать каналы гамма-таблица не умеет,
/// поэтому здесь только тинт, гамма, инверсия и клиппинг
struct GammaSettings: Decodable {
    let tint: [Float]
    let gamma: Float
    let invert: Bool
    let blackPoint: Float
    let whitePoint: Float
}

struct ShaderManifest: Decodable {
    let name: String
    let level: RenderLevel
    let animated: Bool?
    let parameters: [ShaderParameter]?
    let gamma: GammaSettings?
}

/// уровень 1 работает без шейдера, уровень 2 без гамма-таблиц: разные наборы данных,
/// поэтому не опциональные поля, а два случая
enum PluginKind {
    case gamma(GammaSettings)
    case overlay(source: String)
}

struct ShaderPlugin {
    let manifest: ShaderManifest
    let kind: PluginKind
    /// имя папки, используется как стабильный идентификатор в UserDefaults
    let identifier: String

    var isAnimated: Bool { manifest.animated ?? false }
    var defaultParameters: [Float] { (manifest.parameters ?? []).map(\.default) }
}

// ponytail: 8 параметров, потому что uniform-буфер фиксированной длины.
// упирается кто-то в потолок, значит пора переходить на MTLBuffer переменной длины
let maxShaderParameters = 8

enum PluginError: LocalizedError {
    case manifestUnreadable(plugin: String, underlying: Error)
    case sourceMissing(plugin: String)
    case gammaSettingsMissing(plugin: String)
    case invalidGammaTint(plugin: String, count: Int)
    case unsupportedLevel(plugin: String, level: RenderLevel)
    case tooManyParameters(plugin: String, count: Int)
    case compilationFailed(plugin: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .manifestUnreadable(plugin, underlying):
            return "\(plugin): манифест не читается - \(underlying.localizedDescription)"
        case let .sourceMissing(plugin):
            return "\(plugin): рядом с манифестом нет файла shader.metal"
        case let .gammaSettingsMissing(plugin):
            return "\(plugin): уровню 1 нужна секция gamma в манифесте"
        case let .invalidGammaTint(plugin, count):
            return "\(plugin): в tint должно быть 3 значения, а не \(count)"
        case let .unsupportedLevel(plugin, level):
            return "\(plugin): уровень рендеринга \(level.rawValue) ещё не поддерживается"
        case let .tooManyParameters(plugin, count):
            return "\(plugin): параметров \(count), максимум \(maxShaderParameters)"
        case let .compilationFailed(plugin, underlying):
            return "\(plugin): шейдер не компилируется - \(underlying.localizedDescription)"
        }
    }

    var pluginName: String {
        switch self {
        case let .manifestUnreadable(plugin, _),
             let .sourceMissing(plugin),
             let .gammaSettingsMissing(plugin),
             let .invalidGammaTint(plugin, _),
             let .unsupportedLevel(plugin, _),
             let .tooManyParameters(plugin, _),
             let .compilationFailed(plugin, _):
            return plugin
        }
    }
}

/// ~/Library/Application Support/ScreenFilter/Shaders
func shadersDirectory() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("ScreenFilter/Shaders", isDirectory: true)
}

/// копирует встроенные пресеты, которых ещё нет на диске. существующие папки не трогает,
/// иначе правки пользователя затирались бы при каждом старте, но новые пресеты
/// из обновления приложения доезжают
func installBundledPlugins(into directory: URL, from bundle: Bundle = .main) throws {
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
        guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
        try FileManager.default.copyItem(at: entry, to: destination)
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

    return (plugins, errors)
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

    case .overlay:
        let sourceURL = directory.appendingPathComponent("shader.metal")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return .failure(.sourceMissing(plugin: manifest.name))
        }
        let count = manifest.parameters?.count ?? 0
        guard count <= maxShaderParameters else {
            return .failure(.tooManyParameters(plugin: manifest.name, count: count))
        }
        return .success(.overlay(source: source))

    case .capture:
        return .failure(.unsupportedLevel(plugin: manifest.name, level: manifest.level))
    }
}
