// кинопроектор: лампа дышит, углы уходят в тень
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    // две несовпадающие частоты вместо одной: ровный пульс утомляет через минуту,
    // а сумма несоизмеримых частот читается как живая лампа
    float wobble = sin(u.time * 11.0) * 0.6 + sin(u.time * 27.0) * 0.4;
    // яркость только падает: лампа не разгорается ярче, чем горит
    float flicker = max(-wobble, 0.0) * 0.5 * flickerStrength;

    float2 centered = (in.uv - 0.5) * 2.0;
    float vignette = smoothstep(0.35, 1.35, length(centered)) * vignetteStrength;

    return float4(0.0, 0.0, 0.0, saturate(flicker + vignette));
}
