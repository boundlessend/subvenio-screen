// один бит на пиксель с упорядоченным растром Байера: экран макинтоша 1984 года
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float3 color = source.sample(overlay_sampler, overlay_source_uv(in.uv, u)).rgb;
    float luma = saturate((dot(color, float3(0.299, 0.587, 0.114)) - 0.5) * contrast + 0.5);

    // ячейка считается в точках: на Retina растр остаётся крупным и видимым
    float threshold = overlay_bayer4(uint2(in.position.xy / u.scale));
    return float4(float3(luma > threshold ? 1.0 : 0.0), 1.0);
}
