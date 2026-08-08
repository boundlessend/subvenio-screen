// сканлайны плюс виньетка, всё затемняющее: цвет чёрный, значит premultiplied rgb = 0
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    // период задан в точках, домножается на масштаб дисплея: на Retina линии не сгущаются
    float period = scanlinePeriod * u.scale;
    float scan = fract(in.position.y / period) < 0.5 ? scanlineStrength : 0.0;

    float2 centered = (in.uv - 0.5) * 2.0;
    float vignette = smoothstep(0.55, 1.35, length(centered)) * vignetteStrength;

    return float4(0.0, 0.0, 0.0, saturate(scan + vignette));
}
