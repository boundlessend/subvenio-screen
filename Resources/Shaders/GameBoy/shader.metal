// четыре оттенка зелёного и растр между ними: карманная консоль 1989 года
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float3 color = source.sample(overlay_sampler, overlay_source_uv(in.uv, u)).rgb;
    // четырёх ступеней мало для обычного экрана, поэтому диапазон сперва растягивается
    float luma = saturate((dot(color, float3(0.299, 0.587, 0.114)) - 0.34) * contrast + 0.48);

    // растр сдвигает яркость на треть ступени, поэтому переходы не полосят.
    // предел здесь 3, а не 1: ступеней четыре, и saturate схлопнул бы их в две
    float dither = overlay_bayer4(uint2(in.position.xy / u.scale));
    float stepped = clamp(luma * 3.0 + (dither - 0.5) * 0.9, 0.0, 3.0);
    uint shade = uint(floor(stepped + 0.5));

    float3 shades[4] = {
        float3(0.06, 0.22, 0.06),
        float3(0.19, 0.38, 0.19),
        float3(0.55, 0.67, 0.06),
        float3(0.61, 0.74, 0.06)
    };
    return float4(shades[shade], 1.0);
}
