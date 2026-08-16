import Metal
import XCTest

/// проверки только на чистые преобразования: таблицы гаммы, разбор манифеста
/// и раскладка uniform-буфера. всё остальное в этом приложении проверяется глазами
final class GammaTableTests: XCTestCase {
    private let sepia = GammaSettings(
        tint: [1.0, 0.88, 0.72],
        gamma: 1.0,
        invert: false,
        blackPoint: 0.04,
        whitePoint: 0.96
    )

    func testTableSpansTheDeclaredLevelsAndTint() {
        let tables = gammaTables(sepia, size: 256)

        XCTAssertEqual(tables.red.count, 256)
        XCTAssertEqual(tables.red.first ?? 0, 0.04, accuracy: 0.0001)
        XCTAssertEqual(tables.red.last ?? 0, 0.96, accuracy: 0.0001)
        XCTAssertEqual(tables.green.last ?? 0, 0.96 * 0.88, accuracy: 0.0001)
        XCTAssertEqual(tables.blue.last ?? 0, 0.96 * 0.72, accuracy: 0.0001)
    }

    func testTableIsMonotonic() {
        let table = gammaTables(sepia, size: 256).red
        XCTAssertTrue(zip(table, table.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testInvertSwapsTheEnds() {
        let inverted = GammaSettings(
            tint: [1, 1, 1],
            gamma: 1.0,
            invert: true,
            blackPoint: 0,
            whitePoint: 1
        )
        let table = gammaTables(inverted, size: 256)

        XCTAssertEqual(table.red.first ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(table.red.last ?? 0, 0, accuracy: 0.0001)
    }

    /// ёмкость таблицы приходит из системы, а не из наших рук
    func testDegenerateSizeDoesNotProduceNaN() {
        let table = gammaTables(sepia, size: 1)
        XCTAssertFalse(table.red.contains { $0.isNaN || $0.isInfinite })
    }
}

final class PluginLoadingTests: XCTestCase {
    func testValidPluginLoads() throws {
        let directory = try makePlugin(manifest: """
        {"name": "Good", "level": 2, "parameters": [{"name": "amount", "min": 0, "max": 1, "default": 0.5}]}
        """)
        let loaded = loadPlugins(from: directory)

        XCTAssertEqual(loaded.plugins.count, 1)
        XCTAssertTrue(loaded.errors.isEmpty)
    }

    /// такой диапазон роняет слайдер в настройках раньше, чем шейдер доходит до компиляции
    func testInvertedRangeIsRejected() throws {
        let directory = try makePlugin(manifest: """
        {"name": "Broken", "level": 2, "parameters": [{"name": "amount", "min": 1, "max": 0, "default": 0.5}]}
        """)
        let loaded = loadPlugins(from: directory)

        XCTAssertTrue(loaded.plugins.isEmpty)
        guard case .invalidParameterRange? = loaded.errors.first else {
            return XCTFail("expected invalidParameterRange, got \(loaded.errors)")
        }
    }

    func testDefaultOutsideRangeIsRejected() throws {
        let directory = try makePlugin(manifest: """
        {"name": "Broken", "level": 2, "parameters": [{"name": "amount", "min": 0, "max": 1, "default": 5}]}
        """)
        let loaded = loadPlugins(from: directory)

        guard case .invalidParameterDefault? = loaded.errors.first else {
            return XCTFail("expected invalidParameterDefault, got \(loaded.errors)")
        }
    }

    /// имя уходит в #define шейдера, поэтому должно быть идентификатором
    func testParameterNameMustBeAnIdentifier() throws {
        let directory = try makePlugin(manifest: """
        {"name": "Broken", "level": 2, "parameters": [{"name": "am ount;", "min": 0, "max": 1, "default": 0.5}]}
        """)
        let loaded = loadPlugins(from: directory)

        guard case .invalidParameterName? = loaded.errors.first else {
            return XCTFail("expected invalidParameterName, got \(loaded.errors)")
        }
    }

    func testGammaPluginWithoutSettingsIsRejected() throws {
        let directory = try makePlugin(manifest: #"{"name": "Broken", "level": 1}"#)
        let loaded = loadPlugins(from: directory)

        guard case .gammaSettingsMissing? = loaded.errors.first else {
            return XCTFail("expected gammaSettingsMissing, got \(loaded.errors)")
        }
    }

    /// ноль уходит в показатель степени делением на ноль
    func testZeroGammaIsRejected() throws {
        let directory = try makePlugin(manifest: """
        {"name": "Broken", "level": 1, "gamma": {"tint": [1, 1, 1], "gamma": 0,
         "invert": false, "blackPoint": 0, "whitePoint": 1}}
        """)
        let loaded = loadPlugins(from: directory)

        guard case .invalidGammaValue? = loaded.errors.first else {
            return XCTFail("expected invalidGammaValue, got \(loaded.errors)")
        }
    }

    /// точка за пределами [0, 1] схлопывается клиппингом в сплошную заливку экрана
    func testWhitePointOutsideTheRangeIsRejected() throws {
        let directory = try makePlugin(manifest: """
        {"name": "Broken", "level": 1, "gamma": {"tint": [1, 1, 1], "gamma": 1,
         "invert": false, "blackPoint": 0, "whitePoint": 4}}
        """)
        let loaded = loadPlugins(from: directory)

        guard case .invalidGammaValue? = loaded.errors.first else {
            return XCTFail("expected invalidGammaValue, got \(loaded.errors)")
        }
    }

    /// усиление канала выше единицы это приём, а не ошибка
    func testTintAboveOneIsAllowed() throws {
        let directory = try makePlugin(manifest: """
        {"name": "Bright", "level": 1, "gamma": {"tint": [1.4, 1, 1],
         "gamma": 1, "invert": false, "blackPoint": 0, "whitePoint": 1}}
        """)
        let loaded = loadPlugins(from: directory)

        XCTAssertTrue(loaded.errors.isEmpty, "\(loaded.errors.map(\.localizedDescription))")
        XCTAssertEqual(loaded.plugins.count, 1)
    }

    private func makePlugin(manifest: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SubvenioScreenTests-\(UUID().uuidString)")
        let plugin = root.appendingPathComponent("Plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try manifest.write(
            to: plugin.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "fragment float4 overlay_fragment() { return float4(0); }".write(
            to: plugin.appendingPathComponent("shader.metal"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }
}

final class UniformLayoutTests: XCTestCase {
    /// раскладка обязана совпадать со `struct Uniforms` в прологе шейдера:
    /// float2, float, float, float2, float2, float[8]
    func testLayoutMatchesTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<Uniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.resolution), 0)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.scale), 8)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.time), 12)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.sourceOrigin), 16)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.sourceSize), 24)
        XCTAssertEqual(MemoryLayout<Uniforms>.offset(of: \.params), 32)
    }

    func testParametersBeyondTheLimitAreDropped() {
        let values = uniforms(
            resolution: CGSize(width: 100, height: 50),
            scale: 2,
            time: 0,
            sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            parameters: Array(repeating: 1, count: maxShaderParameters + 4)
        )
        XCTAssertEqual(values.params[maxShaderParameters - 1], 1)
        XCTAssertEqual(values.resolution.x, 100)
    }
}

/// доля кадра дисплея, которую занимает оверлей. ошибка здесь выглядит как съехавший
/// эффект в оконном режиме, а такое глазами ловится плохо
final class SourceRectTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1000, height: 500)

    func testWholeDisplayIsTheWholeFrame() {
        XCTAssertEqual(sourceRect(for: display, in: display), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// CGWindowList считает Y вниз от верха, Cocoa вверх от низа: перепутанное
    /// направление уводит эффект в противоположную половину экрана
    func testTopLeftQuarterLandsAtTheOrigin() {
        let window = CGRect(x: 0, y: 250, width: 500, height: 250)
        XCTAssertEqual(
            sourceRect(for: window, in: display),
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        )
    }

    func testBottomRightQuarterLandsAtTheFarCorner() {
        let window = CGRect(x: 500, y: 0, width: 500, height: 250)
        XCTAssertEqual(
            sourceRect(for: window, in: display),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        )
    }

    /// у второго монитора начало координат смещено, а доли считаются от его собственной рамки
    func testSecondDisplayIsMeasuredFromItsOwnBounds() {
        let second = CGRect(x: -1600, y: 200, width: 1600, height: 1000)
        let window = CGRect(x: -1200, y: 700, width: 800, height: 500)
        XCTAssertEqual(
            sourceRect(for: window, in: second),
            CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5)
        )
    }
}

/// установка встроенных пресетов это единственное место, где приложение пишет
/// в чужую папку и может затереть чужую работу, поэтому проверяется целиком
final class BundledInstallTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var bundled: URL!
    private var installed: URL!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "SubvenioScreenTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(suite)
        // Bundle умеет смотреть в обычную папку, поэтому «встроенные» пресеты
        // подделываются директорией и версию их содержимого задаёт тест
        bundled = root.appendingPathComponent("Bundle/Shaders")
        installed = root.appendingPathComponent("Shaders")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try write(preset: "Alpha", body: "float4(0)", to: bundled)
        try write(preset: "Beta", body: "float4(1)", to: bundled)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func write(preset: String, body: String, to directory: URL) throws {
        let folder = directory.appendingPathComponent(preset)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"name": "\#(preset)", "level": 2}"#.write(
            to: folder.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "fragment float4 overlay_fragment() { return \(body); }".write(
            to: folder.appendingPathComponent("shader.metal"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func install() throws {
        let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Bundle")))
        try installBundledPlugins(into: installed, from: bundle, defaults: defaults)
    }

    private func restore() throws {
        let bundle = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Bundle")))
        try restoreBundledPlugins(into: installed, from: bundle, defaults: defaults)
    }

    private func shader(_ preset: String) throws -> String {
        try String(
            contentsOf: installed.appendingPathComponent("\(preset)/shader.metal"),
            encoding: .utf8
        )
    }

    func testPresetsArriveAndSurviveASecondPass() throws {
        try install()
        try install()

        XCTAssertEqual(loadPlugins(from: installed).plugins.count, 2)
    }

    /// правка пользователя дороже нашей копии: обновление её не трогает
    func testAnEditedPresetIsLeftAlone() throws {
        try install()
        try "fragment float4 overlay_fragment() { return float4(0.5); }".write(
            to: installed.appendingPathComponent("Alpha/shader.metal"),
            atomically: true,
            encoding: .utf8
        )
        try write(preset: "Alpha", body: "float4(0.25)", to: bundled)

        try install()

        XCTAssertTrue(try shader("Alpha").contains("0.5"))
    }

    /// а нетронутая копия обязана получить исправление новой версии
    func testAnUntouchedPresetIsUpdated() throws {
        try install()
        try write(preset: "Alpha", body: "float4(0.25)", to: bundled)

        try install()

        XCTAssertTrue(try shader("Alpha").contains("0.25"))
    }

    func testADeletedPresetStaysDeleted() throws {
        try install()
        try FileManager.default.removeItem(at: installed.appendingPathComponent("Beta"))

        try install()

        XCTAssertEqual(loadPlugins(from: installed).plugins.map(\.identifier), ["Alpha"])
    }

    func testRestoreBringsBackWhatWasDeletedAndEdited() throws {
        try install()
        try FileManager.default.removeItem(at: installed.appendingPathComponent("Beta"))
        try "fragment float4 overlay_fragment() { return float4(0.5); }".write(
            to: installed.appendingPathComponent("Alpha/shader.metal"),
            atomically: true,
            encoding: .utf8
        )

        try restore()

        XCTAssertEqual(loadPlugins(from: installed).plugins.count, 2)
        XCTAssertTrue(try shader("Alpha").contains("float4(0)"))
    }
}

/// пресеты, которые уезжают с приложением: битый шейдер здесь дожил бы до релиза,
/// потому что компиляция происходит только при включении эффекта
final class BundledShaderTests: XCTestCase {
    private var shaders: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Shaders")
    }

    func testEveryBundledPresetLoads() throws {
        let loaded = loadPlugins(from: shaders)

        XCTAssertTrue(loaded.errors.isEmpty, "\(loaded.errors.map(\.localizedDescription))")
        XCTAssertFalse(loaded.plugins.isEmpty)
    }

    /// описание видно в меню и в настройках, и пресет без него выглядит недоделанным
    func testEveryBundledPresetDescribesItself() throws {
        for plugin in loadPlugins(from: shaders).plugins {
            XCTAssertNotNil(
                plugin.manifest.description?.resolved,
                "\(plugin.identifier) has no description in this language"
            )
        }
    }

    func testEveryBundledShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("на этой машине нет устройства Metal")
        }
        for plugin in loadPlugins(from: shaders).plugins
        where plugin.manifest.level != .gammaLUT {
            XCTAssertNoThrow(
                try makePipeline(device: device, plugin: plugin),
                plugin.identifier
            )
        }
    }
}

/// заготовка своего пресета: она уезжает человеку под редактирование, поэтому
/// обязана открываться и компилироваться ровно в том виде, в каком её положили
final class PresetTemplateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SubvenioScreenTemplate-\(UUID().uuidString)")
        addTeardownBlock { [directory] in
            try? FileManager.default.removeItem(at: directory!)
        }
    }

    func testTemplateLoadsAndCompiles() throws {
        _ = try createPresetFromTemplate(in: directory)
        let loaded = loadPlugins(from: directory)

        XCTAssertTrue(loaded.errors.isEmpty, "\(loaded.errors.map(\.localizedDescription))")
        let plugin = try XCTUnwrap(loaded.plugins.first)

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("на этой машине нет устройства Metal")
        }
        XCTAssertNoThrow(try makePipeline(device: device, plugin: plugin))
    }

    /// вторая кнопка подряд не должна переписывать первую заготовку
    func testASecondTemplateGetsItsOwnFolder() throws {
        let first = try createPresetFromTemplate(in: directory)
        let second = try createPresetFromTemplate(in: directory)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(loadPlugins(from: directory).plugins.count, 2)
    }
}

final class LocalizedTextTests: XCTestCase {
    private func decode(_ json: String) throws -> LocalizedText {
        try JSONDecoder().decode(LocalizedText.self, from: Data(json.utf8))
    }

    func testAPlainStringIsUsedAsIs() throws {
        XCTAssertEqual(try decode(#""Grain Strength""#).resolved, "Grain Strength")
    }

    /// чужой язык хуже отсутствия строки: подпись собирается из имени параметра
    func testAMissingLanguageResolvesToNothing() throws {
        let text = try decode(#"{"de": "Körnung"}"#)
        XCTAssertNil(text.resolved)
    }

    func testEnglishIsTheFallback() throws {
        let text = try decode(#"{"en": "Grain", "de": "Körnung"}"#)
        XCTAssertEqual(text.resolved, "Grain")
    }
}

final class VersionComparisonTests: XCTestCase {
    func testTagPrefixAndOrderOfComponents() {
        XCTAssertTrue(isVersion("v1.2.0", newerThan: "1.1.9"))
        XCTAssertTrue(isVersion("1.1.1", newerThan: "1.1.0"))
        XCTAssertFalse(isVersion("v1.1.0", newerThan: "1.1.0"))
        XCTAssertFalse(isVersion("1.0.9", newerThan: "1.1.0"))
    }

    /// строковое сравнение поставило бы 1.9 выше 1.10, и обновление не нашлось бы
    func testDoubleDigitComponents() {
        XCTAssertTrue(isVersion("1.10.0", newerThan: "1.9.0"))
        XCTAssertFalse(isVersion("1.9.0", newerThan: "1.10.0"))
    }

    func testMissingAndDecoratedComponents() {
        XCTAssertTrue(isVersion("2", newerThan: "1.9.9"))
        XCTAssertFalse(isVersion("1.1", newerThan: "1.1.0"))
        XCTAssertTrue(isVersion("1.2.0-beta", newerThan: "1.1.0"))
    }
}
