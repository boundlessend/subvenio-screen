// зерно обновляется каждый кадр: тёмные крупинки идут через alpha с чёрным цветом,
// светлые через premultiplied rgb, равный своей же alpha
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    // номер кадра идёт третьей осью хеша, а не смещением аргумента: смещение сдвигало бы
    // один и тот же узор, и зерно ползло бы по экрану вместо того чтобы обновляться.
    // 24 кадра в секунду, как у плёнки: на частоте дисплея зерно слишком гладкое
    float noise = overlay_hash3(float3(in.position.xy, floor(u.time * 24.0))) - 0.5;
    float grain = noise * grainStrength;

    float2 centered = (in.uv - 0.5) * 2.0;
    float vignette = smoothstep(0.5, 1.4, length(centered)) * vignetteStrength;

    float bright = max(grain, 0.0);
    float dark = max(-grain, 0.0) + vignette;

    float alpha = saturate(bright + dark);
    return float4(float3(min(bright, alpha)), alpha);
}
