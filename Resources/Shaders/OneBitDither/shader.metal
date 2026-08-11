// один бит на пиксель с упорядоченным растром Байера: экран макинтоша 1984 года
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    // матрица Байера 4x4: порог зависит от места в ячейке, поэтому полутон выходит
    // узором, а не полосами
    float table[16] = {
        0.0625, 0.5625, 0.1875, 0.6875,
        0.8125, 0.3125, 0.9375, 0.4375,
        0.2500, 0.7500, 0.1250, 0.6250,
        1.0000, 0.5000, 0.8750, 0.3750
    };
    float3 color = source.sample(overlay_sampler, overlay_source_uv(in.uv, u)).rgb;
    float luma = saturate((dot(color, float3(0.299, 0.587, 0.114)) - 0.5) * contrast + 0.5);

    // ячейка считается в точках: на Retina растр остаётся крупным и видимым
    uint2 cell = uint2(in.position.xy / u.scale) & 3u;
    float threshold = table[cell.y * 4u + cell.x];
    return float4(float3(luma > threshold ? 1.0 : 0.0), 1.0);
}
