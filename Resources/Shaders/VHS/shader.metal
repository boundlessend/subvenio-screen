// сиреневая плёнка, строчный шум и светлая полоса помех, ползущая снизу вверх
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    float band = fract(in.uv.y * 1.5 - u.time * 0.12);
    float streak = smoothstep(0.95, 1.0, band) * bandStrength;

    // шум держится строкой и обновляется 24 раза в секунду, как у ленты
    float row = floor(in.position.y / (2.0 * u.scale));
    float noise = (overlay_hash(float2(row, floor(u.time * 24.0))) - 0.5) * noiseStrength;

    float bright = saturate(streak + max(noise, 0.0));
    float dark = max(-noise, 0.0);

    float3 tint = float3(0.45, 0.25, 0.65);
    float alpha = saturate(bright + dark + tintStrength);
    float3 rgb = tint * tintStrength + float3(bright);

    return float4(min(rgb, float3(alpha)), alpha);
}
