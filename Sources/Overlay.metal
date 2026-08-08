#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// полноэкранный треугольник без вершинного буфера
vertex VertexOut overlay_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = p;
    return out;
}

// сканлайны плюс виньетка, вывод в premultiplied alpha: цвет чёрный, значит rgb = 0
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant float &scale [[buffer(0)]]) {
    // период в точках, домноженный на масштаб дисплея: на Retina линии не сгущаются
    float period = 3.0 * scale;
    float scan = fract(in.position.y / period) < 0.5 ? 0.22 : 0.0;

    float2 centered = (in.uv - 0.5) * 2.0;
    float vignette = smoothstep(0.55, 1.35, length(centered)) * 0.55;

    float alpha = saturate(scan + vignette);
    return float4(0.0, 0.0, 0.0, alpha);
}
