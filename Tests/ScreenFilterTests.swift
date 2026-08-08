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

    private func makePlugin(manifest: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScreenFilterTests-\(UUID().uuidString)")
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
