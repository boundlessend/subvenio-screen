import Metal

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

// дешёвый хеш-шум для зерна и полос
inline float overlay_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
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
        fatalError("makePipeline вызван для плагина уровня 1")
    }
    do {
        let library = try device.makeLibrary(
            source: shaderSource(for: plugin, source: source),
            options: nil
        )
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "overlay_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "overlay_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
        throw PluginError.compilationFailed(plugin: plugin.manifest.name, underlying: error)
    }
}

/// раскладка совпадает с struct Uniforms в прологе: float2 + float + float + float[8]
func uniformValues(resolution: CGSize, scale: CGFloat, time: Double, parameters: [Float]) -> [Float] {
    var values: [Float] = [
        Float(resolution.width),
        Float(resolution.height),
        Float(scale),
        Float(time),
    ]
    values.append(contentsOf: parameters)
    values.append(contentsOf: [Float](repeating: 0, count: maxShaderParameters - parameters.count))
    return values
}
