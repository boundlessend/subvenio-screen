// янтарный люминофор: яркость экрана есть, цвета нет. цвет смешивается из каналов,
// а поканальная таблица дисплея этого не умеет, поэтому здесь нужен реальный кадр
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float2 uv = overlay_source_uv(in.uv, u);
    float3 color = source.sample(overlay_sampler, uv).rgb;
    float luma = dot(color, float3(0.299, 0.587, 0.114));

    // светящееся растекается по вертикали, как разгорается точка на люминофоре
    float up = dot(source.sample(overlay_sampler, uv + float2(0.0, -0.004)).rgb,
                   float3(0.299, 0.587, 0.114));
    float down = dot(source.sample(overlay_sampler, uv + float2(0.0, 0.004)).rgb,
                     float3(0.299, 0.587, 0.114));
    luma = saturate(luma + (up + down) * 0.5 * glow);

    float line = fract(in.position.y / (3.0 * u.scale)) < 0.5 ? 1.0 - lineStrength : 1.0;
    return float4(pow(luma, 0.85) * float3(1.0, 0.62, 0.16) * line, 1.0);
}
