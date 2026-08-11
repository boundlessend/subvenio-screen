// износ плёнки: царапины на эмульсии и соринки в кадровом окне. и то и другое живёт
// ровно один кадр плёнки, поэтому номер кадра идёт осью хеша, а не смещением аргумента
fragment float4 overlay_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    // 16 кадров в секунду: старая плёнка, и на этой частоте износ читается как износ,
    // а не как рябь
    float frame = floor(u.time * 16.0);

    // до трёх вертикальных царапин, каждая на своём месте в каждом кадре
    float scratch = 0.0;
    for (int i = 0; i < 3; i++) {
        float seed = overlay_hash3(float3(float(i), frame, 0.0));
        if (seed < 0.45) { continue; }
        float x = overlay_hash3(float3(float(i) + 17.0, frame, 3.0));
        float width = 0.0006 + 0.0016 * overlay_hash3(float3(float(i), frame, 9.0));
        scratch += smoothstep(width, 0.0, abs(in.uv.x - x));
    }
    scratch = saturate(scratch) * scratchStrength;

    // пылинки: редкие тёмные крупинки по кадру, порог отбирает примерно одну на тысячу
    float speck = overlay_hash3(float3(floor(in.position.xy / 2.0), frame));
    float dust = step(0.9992, speck) * dustStrength;

    // царапина светлая и идёт через premultiplied rgb, пыль тёмная и только через alpha
    float alpha = saturate(scratch + dust);
    return float4(float3(min(scratch, alpha)), alpha);
}
