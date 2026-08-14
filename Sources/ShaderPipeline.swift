import Metal
import simd

// ponytail: 8 параметров, потому что uniform-буфер фиксированной длины.
// упирается кто-то в потолок, значит пора переходить на MTLBuffer переменной длины
let maxShaderParameters = 8

/// раскладка uniform-буфера на стороне Swift. поля и порядок обязаны совпадать
/// со `struct Uniforms` в прологе ниже; совпадение проверяется рефлексией пайплайна
/// при компиляции каждого шейдера, поэтому расхождение всплывает сразу, а не мусором на экране
struct Uniforms {
    var resolution: SIMD2<Float>
    var scale: Float
    var time: Float
    /// какой кусок кадра дисплея показывает этот оверлей, в долях от кадра
    var sourceOrigin: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var params: SIMD8<Float>
}

/// пролог, который движок подставляет перед исходником плагина:
/// вершинная функция, uniform-структура и общие хелперы. плагин пишет только фрагментную функцию
private let shaderPrelude = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct Uniforms {
    float2 resolution;
    float scale;
    float time;
    // какой кусок кадра дисплея показывает этот оверлей: под окном он меньше экрана
    float2 sourceOrigin;
    float2 sourceSize;
    float params[\(maxShaderParameters)];
};

vertex VertexOut overlay_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    // uv с началом в левом верхнем углу, как у текстуры захвата
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// сэмплер для уровня 3: плагин читает им кадр из source
constexpr sampler overlay_sampler(coord::normalized, address::clamp_to_edge, filter::linear);

// целочисленный хеш-шум для зерна и полос.
// классический fract(sin(dot(...))) здесь не годится: шейдеры подмешивают в аргумент
// время, sin в Metal теряет точность на больших числах, и через четыре минуты работы
// шум вырождался в ровную заливку - зерно пропадало прямо на экране.
// третья ось нужна под номер кадра: без неё анимировать двумерный шум можно только
// сдвигом аргумента, а сдвиг это не новый узор, а тот же самый, уехавший по диагонали
inline float overlay_hash3(float3 p) {
    uint3 q = uint3(int3(floor(p)));
    uint h = q.x * 73856093u ^ q.y * 19349663u ^ q.z * 83492791u;
    h ^= h >> 13;
    h *= 0x5bd1e995u;
    h ^= h >> 15;
    return float(h) * (1.0 / 4294967296.0);
}

inline float overlay_hash(float2 p) {
    return overlay_hash3(float3(p, 0.0));
}

// координата в кадре захвата: на весь экран это те же uv, под окном сдвиг и масштаб
inline float2 overlay_source_uv(float2 uv, constant Uniforms &u) {
    return u.sourceOrigin + uv * u.sourceSize;
}

"""

/// параметры манифеста становятся именованными макросами: в шейдере пишут `scanlineStrength`,
/// а не `u.params[0]`. соглашение: uniform-аргумент фрагментной функции обязан называться `u`
private func parameterDefines(_ parameters: [ShaderParameter]) -> String {
    parameters.enumerated()
        .map { "#define \($1.name) u.params[\($0)]\n" }
        .joined()
}

func shaderSource(for plugin: ShaderPlugin, source: String) -> String {
    shaderPrelude + parameterDefines(plugin.manifest.parameters ?? []) + "\n" + source
}

// ponytail: компиляция занимает сотни миллисекунд и результат живёт в памяти до выхода.
// дисковый кеш через MTLBinaryArchive появится, когда пресетов станет много или старт станет заметным
func makePipeline(device: MTLDevice, plugin: ShaderPlugin) throws -> MTLRenderPipelineState {
    let source: String
    switch plugin.kind {
    case let .overlay(text), let .capture(text):
        source = text
    case .gamma:
        throw PluginError.unsupportedLevel(plugin: plugin.manifest.name, level: .gammaLUT)
    }

    let library: MTLLibrary
    do {
        library = try device.makeLibrary(
            source: shaderSource(for: plugin, source: source),
            options: nil
        )
    } catch {
        throw PluginError.compilationFailed(plugin: plugin.manifest.name, underlying: error)
    }

    guard let fragment = library.makeFunction(name: "overlay_fragment") else {
        throw PluginError.fragmentFunctionMissing(plugin: plugin.manifest.name)
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "overlay_vertex")
    descriptor.fragmentFunction = fragment
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

    do {
        var reflection: MTLRenderPipelineReflection?
        let pipeline = try device.makeRenderPipelineState(
            descriptor: descriptor,
            options: [.bindingInfo],
            reflection: &reflection
        )
        try checkUniformLayout(reflection)
        return pipeline
    } catch let error as PluginError {
        throw error
    } catch {
        throw PluginError.compilationFailed(plugin: plugin.manifest.name, underlying: error)
    }
}

/// скомпилированные пайплайны переживают переключение пресета: компиляция стоит
/// сотни миллисекунд, и без кеша перебор списка в настройках платит их на каждом шаге.
/// ключ включает исходник, поэтому правка shader.metal на диске даёт новый пайплайн,
/// а не поднимает прежний из кеша.
///
/// кеш один на приложение: превью и оверлей показывают один и тот же шейдер, и
/// раздельные кеши компилировали каждый пресет дважды и чистились по-разному.
/// изоляция главным актором выражена типом, а не соглашением: и оверлей, и вью
/// превью живут на нём, так что цена нулевая, а на Swift 6 это условие проверки
@MainActor
final class PipelineCache {
    static let shared = PipelineCache()

    private struct Key: Hashable {
        let identifier: String
        let source: String
    }

    private var pipelines: [Key: MTLRenderPipelineState] = [:]

    func pipeline(for plugin: ShaderPlugin, device: MTLDevice) throws -> MTLRenderPipelineState {
        let source: String
        switch plugin.kind {
        case let .overlay(text), let .capture(text):
            source = text
        case .gamma:
            throw PluginError.unsupportedLevel(plugin: plugin.manifest.name, level: .gammaLUT)
        }

        let key = Key(identifier: plugin.identifier, source: source)
        if let cached = pipelines[key] {
            return cached
        }
        let pipeline = try makePipeline(device: device, plugin: plugin)
        // прежняя редакция того же пресета больше не нужна
        pipelines = pipelines.filter { $0.key.identifier != plugin.identifier }
        pipelines[key] = pipeline
        return pipeline
    }

    /// пресеты пропали с диска: их пайплайны больше не нужны
    func forget(keeping identifiers: Set<String>) {
        pipelines = pipelines.filter { identifiers.contains($0.key.identifier) }
    }
}

/// сверяет размер uniform-буфера, который ждёт шейдер, с тем, что шлёт Swift.
/// ошибка здесь означает расхождение пролога и `struct Uniforms`, а не вину плагина
private func checkUniformLayout(_ reflection: MTLRenderPipelineReflection?) throws {
    guard let binding = reflection?.fragmentBindings.first(where: {
        $0.index == 0 && $0.type == .buffer
    }) as? MTLBufferBinding else {
        return
    }
    let expected = MemoryLayout<Uniforms>.stride
    guard binding.bufferDataSize == expected else {
        throw UniformLayoutError.sizeMismatch(shader: binding.bufferDataSize, swift: expected)
    }
}

enum UniformLayoutError: LocalizedError {
    case sizeMismatch(shader: Int, swift: Int)

    var errorDescription: String? {
        switch self {
        case let .sizeMismatch(shader, swift):
            return String(
                format: String(localized: "uniform layout mismatch: the shader expects %lld bytes, the app sends %lld"),
                shader, swift
            )
        }
    }
}

func uniforms(
    resolution: CGSize,
    scale: CGFloat,
    time: Double,
    sourceRect: CGRect,
    parameters: [Float]
) -> Uniforms {
    var params = SIMD8<Float>(repeating: 0)
    for (index, value) in parameters.prefix(maxShaderParameters).enumerated() {
        params[index] = value
    }
    return Uniforms(
        resolution: SIMD2(Float(resolution.width), Float(resolution.height)),
        scale: Float(scale),
        time: Float(time),
        sourceOrigin: SIMD2(Float(sourceRect.origin.x), Float(sourceRect.origin.y)),
        sourceSize: SIMD2(Float(sourceRect.width), Float(sourceRect.height)),
        params: params
    )
}
