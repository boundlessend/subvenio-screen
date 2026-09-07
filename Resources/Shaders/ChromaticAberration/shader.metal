// дешёвая оптика: каналы расходятся тем сильнее, чем дальше от центра кадра
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
    float2 uv = overlay_source_uv(in.uv, u);
    // от центра области эффекта, а не экрана: в оконном режиме кадр захвата шире
    // окна, и расхождение каналов уезжало бы к середине монитора
    float2 centered = in.uv - 0.5;
    // edgeBias на нуле разводит каналы одинаково по всему кадру, на единице только
    // по краям, как настоящая линза. радиус меряется в пикселях и нормируется по
    // короткой стороне: в долях кадра спад по горизонтали наступал раньше,
    // чем по вертикали, и край у линзы выходил овальным
    float2 radial = centered * u.resolution / min(u.resolution.x, u.resolution.y);
    float falloff = mix(1.0, dot(radial, radial) * 4.0, edgeBias);
    // смещение считается в пикселях: в долях кадра тот же сдвиг по горизонтали
    // покрывал бы почти вдвое больше точек, чем по вертикали
    float2 shift = overlay_source_offset(centered * u.resolution * amount * falloff, u);

    float red = source.sample(overlay_sampler, uv + shift).r;
    float green = source.sample(overlay_sampler, uv).g;
    float blue = source.sample(overlay_sampler, uv - shift).b;
    return float4(red, green, blue, 1.0);
}
