// ореол вокруг светлого: так светится люминофор и так засвечивается плёнка,
// когда свет проходит эмульсию насквозь и отражается обратно
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float2 uv = overlay_source_uv(in.uv, u);
    float3 base = source.sample(overlay_sampler, uv).rgb;

    // двенадцать отсчётов по кольцу вместо честного размытия: разница на глаз
    // не видна, а проходов по кадру остаётся один
    float3 glow = float3(0.0);
    for (int i = 0; i < 12; i++) {
        float angle = float(i) * 0.5236;
        float radius = 0.008 + 0.014 * float(i % 3);
        float2 offset = float2(cos(angle), sin(angle)) * radius;
        float3 sampled = source.sample(overlay_sampler, uv + offset).rgb;
        glow += max(sampled - threshold, 0.0);
    }
    glow /= 12.0;

    // ореол тёплый: на плёнке засветка идёт через красный слой
    float3 warm = float3(1.0, 0.72, 0.52);
    return float4(saturate(base + glow * warm * strength * 6.0), 1.0);
}
