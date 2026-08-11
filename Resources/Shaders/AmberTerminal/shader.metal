// люминофор терминала: яркость экрана есть, цвета нет. цвет смешивается из каналов,
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

    // цвет трубки берётся с круга оттенков: 0.09 даёт янтарь, 0.36 зелёный P1.
    // насыщенность фиксирована: у обеих трубок она одна и та же, а ползунок,
    // умеющий обесцветить картинку до белой, здесь никому не нужен
    float3 wheel = clamp(
        abs(fract(hue + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    float3 phosphor = mix(float3(1.0), wheel, 0.82);

    float line = fract(in.position.y / (3.0 * u.scale)) < 0.5 ? 1.0 - lineStrength : 1.0;
    return float4(pow(luma, 0.85) * phosphor * line, 1.0);
}
