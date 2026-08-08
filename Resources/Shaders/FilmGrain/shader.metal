// зерно обновляется каждый кадр: тёмные крупинки идут через alpha с чёрным цветом,
// светлые через premultiplied rgb, равный своей же alpha
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    float noise = overlay_hash(in.position.xy + u.time * 61.0) - 0.5;
    float grain = noise * grainStrength;

    float2 centered = (in.uv - 0.5) * 2.0;
    float vignette = smoothstep(0.5, 1.4, length(centered)) * vignetteStrength;

    float bright = max(grain, 0.0);
    float dark = max(-grain, 0.0) + vignette;

    float alpha = saturate(bright + dark);
    return float4(float3(min(bright, alpha)), alpha);
}
