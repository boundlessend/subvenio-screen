// дешёвая оптика: каналы расходятся тем сильнее, чем дальше от центра кадра
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float2 uv = overlay_source_uv(in.uv, u);
    float2 centered = uv - 0.5;
    // edgeBias на нуле разводит каналы одинаково по всему кадру, на единице только
    // по краям, как настоящая линза
    float falloff = mix(1.0, dot(centered, centered) * 4.0, edgeBias);

    float red = source.sample(overlay_sampler, 0.5 + centered * (1.0 + amount * falloff)).r;
    float green = source.sample(overlay_sampler, uv).g;
    float blue = source.sample(overlay_sampler, 0.5 + centered * (1.0 - amount * falloff)).b;
    return float4(red, green, blue, 1.0);
}
