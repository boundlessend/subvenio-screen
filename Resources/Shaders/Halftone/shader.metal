// газетный растр: точка тем крупнее, чем темнее место под ней
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float3 color = source.sample(overlay_sampler, overlay_source_uv(in.uv, u)).rgb;
    float luma = saturate((dot(color, float3(0.299, 0.587, 0.114)) - 0.5) * contrast + 0.5);

    float size = cellSize * u.scale;
    // решётка повёрнута на 45 градусов, как в печати: по горизонтали и вертикали
    // ряды точек спорили бы с пикселями экрана и давали муар
    float2 turned = float2(in.position.x + in.position.y, in.position.y - in.position.x) * 0.7071;
    float2 offset = fract(turned / size) - 0.5;

    // радиус в долях ячейки: 0.72 закрывает ячейку целиком в чёрном
    float radius = sqrt(saturate(1.0 - luma)) * 0.72;
    float ink = smoothstep(radius, radius - 0.12, length(offset));
    return float4(float3(1.0 - ink), 1.0);
}
