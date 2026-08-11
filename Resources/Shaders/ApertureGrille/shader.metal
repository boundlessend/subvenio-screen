// апертурная решётка: каждый третий столбец отдан своему люминофору, как у тринитрона.
// маска гасит два канала из трёх, а слой уровня 2 композитится через одну общую
// альфу и поканально гасить не умеет, поэтому решётка живёт на уровне 3
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float3 color = source.sample(overlay_sampler, overlay_source_uv(in.uv, u)).rgb;

    // столбец считается в точках, а не в пикселях: на Retina решётка не сгущается
    uint column = uint(in.position.x / u.scale) % 3u;
    float3 mask = column == 0u ? float3(1.0, 0.0, 0.0)
                : column == 1u ? float3(0.0, 1.0, 0.0)
                               : float3(0.0, 0.0, 1.0);
    mask = mix(float3(1.0), mask, maskStrength);

    // маска забирает часть света, поэтому картинку приходится поднимать обратно
    return float4(saturate(color * mask * brightness), 1.0);
}
