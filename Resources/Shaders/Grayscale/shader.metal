// честный ЧБ: гамма-таблица поканальная и смешать каналы не может, поэтому здесь
// нужен реальный кадр экрана. alpha = 1, кадр полностью заменяет то, что под окном
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float3 color = source.sample(overlay_sampler, overlay_source_uv(in.uv, u)).rgb;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    return float4(mix(color, float3(luma), amount), 1.0);
}
