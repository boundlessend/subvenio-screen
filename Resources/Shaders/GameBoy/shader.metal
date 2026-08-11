// четыре оттенка зелёного и растр между ними: карманная консоль 1989 года
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float table[16] = {
        0.0625, 0.5625, 0.1875, 0.6875,
        0.8125, 0.3125, 0.9375, 0.4375,
        0.2500, 0.7500, 0.1250, 0.6250,
        1.0000, 0.5000, 0.8750, 0.3750
    };
    float3 color = source.sample(overlay_sampler, overlay_source_uv(in.uv, u)).rgb;
    // четырёх ступеней мало для обычного экрана, поэтому диапазон сперва растягивается
    float luma = saturate((dot(color, float3(0.299, 0.587, 0.114)) - 0.34) * contrast + 0.48);

    uint2 cell = uint2(in.position.xy / u.scale) & 3u;
    // растр сдвигает яркость на треть ступени, поэтому переходы не полосят.
    // предел здесь 3, а не 1: ступеней четыре, и saturate схлопнул бы их в две
    float stepped = clamp(luma * 3.0 + (table[cell.y * 4u + cell.x] - 0.5) * 0.9, 0.0, 3.0);
    uint shade = uint(floor(stepped + 0.5));

    float3 shades[4] = {
        float3(0.06, 0.22, 0.06),
        float3(0.19, 0.38, 0.19),
        float3(0.55, 0.67, 0.06),
        float3(0.61, 0.74, 0.06)
    };
    return float4(shades[shade], 1.0);
}
