// blackhole: многодырный пост-эффект с трассировкой луча (до 8 записей). Данные — modules/fx.lua каждый кадр:
//   u_holes[i] = (x, y, z, rh)        центр в мире, радиус горизонта (вспышка: радиус кольца), блоки
//   u_info[i]  = (nx, ny, nz, k)      ось вращения диска, сила
//   u_info2[i] = (spin, flash, outer, merge)
// Камера — штатные униформы эффекта: u_cameraPos, u_view, u_projection (тот же кадр, что и сцена).
// Луч пикселя идёт в пространстве мира относительно камеры; в зоне влияния дыр (8 rh) его направление изгибается к
// центрам (как rd = mix(rd, bdir, ...) в эталоне onigiri: здесь rd += sum(K rh q / |q|^3) ds, полный угол отклонения
// ~ 2K rh / b); шаг адаптивный (меньше у горизонта), не больше MAX_STEPS. Горизонты нескольких дыр объединены
// smooth-min расстояний (видно «втекание» при слиянии). Аккреционный диск — тонкий, процедурный: при каждом пересечении
// лучом плоскости диска цвет берётся из 3D-шума в координатах диска с дифференциальным вращением (внутри быстрее),
// цвет — от бело-голубого горячего края к тёмно-красному холодному, доплеровское усиление приближающейся стороны.
// Изогнутый луч после выхода из зоны — снова в экран (u_screen) по своему направлению: это и есть преломление сцены.
// Глубина (u_depth = 1, только при graphics.advanced-render: есть G-буфер u_position, видовые координаты): поверхность
// пикселя ближе центра дыры (точки наибольшего сближения луча с центром) — перед дырой: стена или склон не линзируются
// и закрывают горизонт и диск. Без G-буфера (advanced-render выключен) эффект рисуется поверх всего, как в волне 1.
#param vec4 u_holes[8]
#param vec4 u_info[8]
#param vec4 u_info2[8]
#param int u_count = 0
#param int u_depth = 0

#define MAX_STEPS 72
#define SR 8.0

float bh_hash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float bh_noise(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(bh_hash(i + vec3(0, 0, 0)), bh_hash(i + vec3(1, 0, 0)), f.x),
                   mix(bh_hash(i + vec3(0, 1, 0)), bh_hash(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(bh_hash(i + vec3(0, 0, 1)), bh_hash(i + vec3(1, 0, 1)), f.x),
                   mix(bh_hash(i + vec3(0, 1, 1)), bh_hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float bh_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// излучение тонкого диска в точке пересечения q (относительно центра, в радиусах горизонта)
vec4 bh_disk(vec3 q, vec3 n, vec3 rdir, float spin, float k, float outer, float seed) {
    vec3 a = abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 e1 = normalize(cross(n, a));
    vec3 e2 = cross(n, e1);
    vec2 pl = vec2(dot(q, e1), dot(q, e2));
    float rr = length(pl);
    float inner = 2.1;
    if (rr < inner * 0.8 || rr > outer) return vec4(0.0);
    float ph = atan(pl.y, pl.x);
    // дифференциальное вращение: угловая скорость ~ r^-1.5
    float phr = ph - spin * 2.4 * pow(rr, -1.5) * u_timer;
    vec2 cs = vec2(cos(phr), sin(phr));
    float n1 = bh_noise(vec3(cs * rr * 1.7, rr * 0.6 + seed));
    float n2 = bh_noise(vec3(rr * 6.5, cs * 2.2 + seed));          // волокна вдоль орбиты
    float n3 = bh_noise(vec3(cs * rr * 5.0, rr * 2.0 - seed));
    float dens = smoothstep(inner * 0.8, inner * 1.1, rr) * (1.0 - smoothstep(outer * 0.5, outer, rr));
    float fil = clamp(n1 * 0.55 + n2 * 0.55 + n3 * 0.25 - 0.35, 0.0, 1.0);
    dens *= 0.08 + 1.6 * fil * fil;
    // температура: горячий бело-голубой у внутреннего края -> тёмно-красный снаружи
    float T = clamp(pow(inner / rr, 1.1), 0.0, 1.0);
    vec3 hot = vec3(0.80, 0.90, 1.00);
    vec3 mid = vec3(1.00, 0.45, 0.18);
    vec3 cold = vec3(0.45, 0.06, 0.10);
    vec3 col = T > 0.5 ? mix(mid, hot, (T - 0.5) * 2.0) : mix(cold, mid, T * 2.0);
    // доплер: приближающаяся сторона ярче и синее
    vec3 vdir = spin * normalize(cross(n, q) + 1e-6);
    float beta = 0.5 * sqrt(inner / rr);
    float g = 1.0 / max(0.2, 1.0 - beta * dot(vdir, -rdir));
    float boost = clamp(g * g * g, 0.15, 4.0);
    col *= mix(vec3(1.25, 0.75, 0.6), vec3(0.75, 0.95, 1.3), clamp((g - 0.7) / 0.9, 0.0, 1.0));
    float alpha = clamp(dens * 0.85, 0.0, 0.9);
    return vec4(col * boost * dens * (1.6 + 0.6 * min(k, 2.0)), alpha);
}

vec2 bh_to_uv(vec3 rdw, float tanX, float tanY, out bool ok) {
    vec3 v = mat3(u_view) * rdw;
    ok = v.z < -1e-3;
    vec2 s = (v.xy / max(-v.z, 1e-3)) / vec2(tanX, tanY);
    return s * 0.5 + 0.5;
}

vec4 effect() {
    vec2 uv = v_uv;
    vec4 base = texture(u_screen, uv);
    if (u_count <= 0) return base;
    float tanX = 1.0 / u_projection[0][0];
    float tanY = 1.0 / u_projection[1][1];
    vec2 ndc = uv * 2.0 - 1.0;
    vec3 rd0 = normalize(mat3(u_inverseView) * vec3(ndc.x * tanX, ndc.y * tanY, -1.0));

    // вспышки коллапса и отрезок луча через зоны влияния дыр
    vec3 glow = vec3(0.0);
    float tStart = 1e9, tEnd = 0.0, tOcc = 1e9;
    int nh = 0;
    for (int i = 0; i < 8; i++) {
        if (i >= u_count) break;
        vec4 h = u_holes[i];
        vec4 e2 = u_info2[i];
        vec3 c = h.xyz - u_cameraPos;
        float tc = dot(c, rd0);
        if (e2.y > 0.0) {
            float dp = length(c - rd0 * max(tc, 0.0));
            float w = 0.12 * h.w + 0.05;
            glow += vec3(1.0, 0.85, 0.65) * e2.y * (1.6 * exp(-pow((dp - h.w) / w, 2.0)) + 1.2 * exp(-dp / (0.35 * h.w + 0.05)));
            glow += vec3(0.5, 0.7, 1.0) * e2.y * 0.6 * exp(-pow((dp - h.w * 0.8) / w, 2.0));
            continue;
        }
        float Sw = h.w * SR;
        float disc = tc * tc - (dot(c, c) - Sw * Sw);
        if (disc > 0.0) {
            float sq = sqrt(disc);
            float t1 = tc + sq;
            if (t1 > 0.0) {
                tStart = min(tStart, max(tc - sq, 0.0));
                tEnd = max(tEnd, t1);
                tOcc = min(tOcc, max(tc, 0.0));
                nh++;
            }
        }
    }
    // расстояние до поверхности этого пикселя. Небо в G-буфере: позиция не записана (w = 0, буфер очищен нулями)
    // или направление * 1e6 (фон background.glslf)
    float sceneD = 1e9;
    if (u_depth != 0) {
        vec4 gp = texture(u_position, uv);
        float l = length(gp.xyz);
        if (gp.w > 0.5 && l > 1e-3 && l < 1e5) sceneD = l;
    }
    if (nh == 0 || sceneD <= tOcc) return vec4(base.rgb + glow * u_intensity, 1.0);

    vec3 p = rd0 * tStart;
    vec3 rd = rd0;
    vec3 col = vec3(0.0);
    float trans = 1.0;
    bool absorbed = false;
    float prevH[8];
    for (int i = 0; i < 8; i++) {
        prevH[i] = 0.0;
        if (i < u_count) prevH[i] = dot(p - (u_holes[i].xyz - u_cameraPos), u_info[i].xyz);
    }
    for (int s = 0; s < MAX_STEPS; s++) {
        vec3 acc = vec3(0.0);
        float H = 1e9;
        float dmin = 1e9;
        float rhmin = 1e9;
        bool inside = false;
        for (int i = 0; i < 8; i++) {
            if (i >= u_count) break;
            vec4 h = u_holes[i];
            vec4 e2 = u_info2[i];
            if (e2.y > 0.0 || h.w <= 0.0) continue;
            vec3 q = p - (h.xyz - u_cameraPos);
            float r = length(q);
            float rn = r / h.w;
            float K = 1.0 + 0.5 * min(u_info[i].w, 2.0);
            float fade = 1.0 - smoothstep(SR * 0.55, SR, rn);
            acc -= q * (K * h.w * fade / (r * r * r + 1e-6));
            float dh = r - h.w;
            H = (H > 1e8) ? dh : bh_smin(H, dh, 0.5 * min(h.w, rhmin));
            rhmin = min(rhmin, h.w);
            dmin = min(dmin, dh);
            if (rn < SR * 1.02) inside = true;
        }
        if (H < 0.0) { absorbed = true; break; }
        if (!inside) {
            // вне всех зон: прыжок до входа в следующую зону по текущему направлению, иначе — конец
            float tn = 1e9;
            for (int i = 0; i < 8; i++) {
                if (i >= u_count) break;
                vec4 h = u_holes[i];
                if (u_info2[i].y > 0.0 || h.w <= 0.0) continue;
                vec3 c = (h.xyz - u_cameraPos) - p;
                float tc = dot(c, rd);
                float Sw = h.w * SR;
                float disc = tc * tc - (dot(c, c) - Sw * Sw);
                if (disc > 0.0) {
                    float t0 = tc - sqrt(disc);
                    if (t0 > 0.0) tn = min(tn, t0);
                }
            }
            if (tn > 1e8) break;
            p += rd * (tn + 1e-3);
            for (int i = 0; i < 8; i++) {
                if (i < u_count) prevH[i] = dot(p - (u_holes[i].xyz - u_cameraPos), u_info[i].xyz);
            }
            continue;
        }
        float ds = clamp(0.3 * dmin, 0.04 * rhmin, 3.0 * rhmin);
        vec3 pn = p + rd * ds;
        // пересечения плоскостей дисков на этом шаге
        for (int i = 0; i < 8; i++) {
            if (i >= u_count) break;
            vec4 h = u_holes[i];
            vec4 e2 = u_info2[i];
            if (e2.y > 0.0 || h.w <= 0.0) continue;
            vec3 cc = h.xyz - u_cameraPos;
            float hn = dot(pn - cc, u_info[i].xyz);
            float hp = prevH[i];
            if (hn * hp < 0.0 && trans > 0.01) {
                vec3 pc = mix(p, pn, hp / (hp - hn));
                vec4 d = bh_disk((pc - cc) / h.w, u_info[i].xyz, rd, e2.x, u_info[i].w, e2.z, float(i) * 13.7);
                col += trans * d.rgb * d.a;
                trans *= 1.0 - d.a;
            }
            prevH[i] = hn;
        }
        rd = normalize(rd + acc * ds);
        p = pn;
    }
    vec3 bg = vec3(0.0);
    if (!absorbed) {
        bool ok;
        vec2 suv = bh_to_uv(rd, tanX, tanY, ok);
        // хроматическая аберрация пропорциональна отклонению луча
        vec2 defl = suv - uv;
        float ca = clamp(length(defl) * 0.04, 0.0, 0.006);
        vec2 cad = length(defl) > 1e-5 ? normalize(defl) * ca : vec2(0.0);
        if (ok) {
            bg.r = texture(u_screen, clamp(suv + cad, 0.0, 1.0)).r;
            bg.g = texture(u_screen, clamp(suv, 0.0, 1.0)).g;
            bg.b = texture(u_screen, clamp(suv - cad, 0.0, 1.0)).b;
            // за краем экрана картинки нет: к краю — в цвет неба по направлению
            float edge = max(max(-suv.x, suv.x - 1.0), max(-suv.y, suv.y - 1.0));
            if (edge > 0.0) bg = mix(bg, texture(u_skybox, rd).rgb, clamp(edge * 4.0, 0.0, 1.0));
        } else {
            bg = texture(u_skybox, rd).rgb;
        }
    }
    vec3 c = col + trans * bg;
    c = mix(base.rgb, c, u_intensity);
    return vec4(c + glow * u_intensity, 1.0);
}
