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

struct ShaderManifest: Decodable {
    let name: String
    let level: RenderLevel
    let animated: Bool?
    let parameters: [ShaderParameter]
}

struct ShaderPlugin {
    let manifest: ShaderManifest
    let source: String
    /// имя папки, используется как стабильный идентификатор в UserDefaults
    let identifier: String

    var isAnimated: Bool { manifest.animated ?? false }
    var defaultParameters: [Float] { manifest.parameters.map(\.default) }
}

// ponytail: 8 параметров, потому что uniform-буфер фиксированной длины.
// упирается кто-то в потолок, значит пора переходить на MTLBuffer переменной длины
let maxShaderParameters = 8

enum PluginError: LocalizedError {
    case manifestUnreadable(plugin: String, underlying: Error)
    case sourceMissing(plugin: String)
    case unsupportedLevel(plugin: String, level: RenderLevel)
    case tooManyParameters(plugin: String, count: Int)
    case compilationFailed(plugin: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .manifestUnreadable(plugin, underlying):
            return "\(plugin): манифест не читается - \(underlying.localizedDescription)"
        case let .sourceMissing(plugin):
            return "\(plugin): рядом с манифестом нет файла shader.metal"
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

/// копирует встроенные пресеты при первом запуске: если папка уже есть, её не трогаем,
/// иначе правки пользователя затирались бы при каждом старте
func installBundledPlugins(into directory: URL, from bundle: Bundle = .main) throws {
    guard !FileManager.default.fileExists(atPath: directory.path) else { return }
    guard let bundled = bundle.url(forResource: "Shaders", withExtension: nil) else {
        throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(
        at: directory.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: bundled, to: directory)
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
        let name = entry.lastPathComponent
        let manifestURL = entry.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }

        do {
            let manifest = try JSONDecoder().decode(
                ShaderManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            let sourceURL = entry.appendingPathComponent("shader.metal")
            guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
                errors.append(.sourceMissing(plugin: manifest.name))
                continue
            }
            guard manifest.level == .overlay else {
                errors.append(.unsupportedLevel(plugin: manifest.name, level: manifest.level))
                continue
            }
            guard manifest.parameters.count <= maxShaderParameters else {
                errors.append(.tooManyParameters(plugin: manifest.name, count: manifest.parameters.count))
                continue
            }
            plugins.append(ShaderPlugin(manifest: manifest, source: source, identifier: name))
        } catch {
            errors.append(.manifestUnreadable(plugin: name, underlying: error))
        }
    }

    return (plugins, errors)
}
