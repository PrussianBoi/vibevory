// Aurora: northern lights over a night sky, hills and a spruce line.
// Ported from Zephyr's sky shader (https://github.com/Peteryhs/zephyr, MIT, (c) 2026 Peteryhs),
// aurora branch only, as a SwiftUI `colorEffect`. Same five curtains, palettes and motion.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace aurora {

inline float sat(float v) { return clamp(v, 0.0, 1.0); }

inline float hash(float2 p) {
    float3 v = fract(float3(p.x, p.y, p.x) * 0.1031);
    v += dot(v, v.yzx + 33.33);
    return fract((v.x + v.y) * v.z);
}

inline float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 q = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(mix(hash(i), hash(i + float2(1, 0)), q.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), q.x), q.y);
}

inline float field(float2 p) {
    float total = 0.0, amplitude = 0.52;
    const float2x2 m = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
    for (int i = 0; i < 4; i++) { total += amplitude * noise(p); p = m * p * 1.9; amplitude *= 0.5; }
    return total;
}

} // namespace aurora

using namespace aurora;

/// position: SwiftUI pixel position (y down). size: view size in the same units.
/// scale: pixels per point of the rendered layer, so stars keep their size. t: seconds.
[[ stitchable ]] half4 auroraSky(float2 position, half4 color, float2 size, float scale, float t) {
    float2 res = size;
    float2 pixel = float2(position.x, size.y - position.y);   // GL convention: y up
    float2 uv = pixel / res;
    float det = min(res.y, mix(res.x, res.y, 0.15));

    float X = uv.x * res.x / res.y, W = res.x / res.y, y = uv.y;

    // deep navy overhead, a lighter blue toward the horizon
    float3 c = mix(float3(0.075, 0.105, 0.175), float3(0.012, 0.018, 0.048), smoothstep(0.0, 0.95, y));

    // stars
    float2 sg = pixel / (3.2 * det / 300.0);
    float2 cell = floor(sg), fp = fract(sg) - 0.5;
    float sh = hash(cell);
    float star = step(0.982, sh) * smoothstep(0.32, 0.0, length(fp + 0.3 * (float2(hash(cell + 7.1), hash(cell + 3.3)) - 0.5)));
    float twinkle = 0.6 + 0.4 * sin(t * (1.0 + 3.0 * hash(cell + 1.7)) + 6.28 * sh);
    c += float3(0.85, 0.90, 1.0) * star * twinkle * (0.25 + 0.75 * fract(sh * 91.0)) * 0.8 * smoothstep(0.15, 0.5, y);

    float3 acc = float3(0);
    const float3 green = float3(0.05, 1.0, 0.40), lime = float3(0.55, 1.0, 0.20), teal = float3(0.02, 0.82, 0.62);
    const float3 pink = float3(1.0, 0.16, 0.36), coral = float3(1.0, 0.38, 0.36), violet = float3(0.42, 0.20, 1.0);
    const float3 auCyan = float3(0.05, 0.80, 1.0), auBlue = float3(0.14, 0.38, 1.0);
    float S = W / 1.6;
    // a slow substorm cycle: the whole display swells and quiets over a couple of minutes
    float storm = sat(0.55 + 0.30 * sin(0.021 * t) + 0.15 * sin(0.053 * t + 2.0));
    float2 vp = float2(0.95 * S, 2.2);
    float angR = atan2(X - vp.x, vp.y - y);

    for (int k = 0; k < 5; k++) {
        float fk = float(k);
        float x0 = S * (k == 0 ? 0.12 : k == 1 ? 0.50 : k == 2 ? 0.86 : k == 3 ? 1.12 : 1.47) + 0.06 * S * sin(0.007 * t + 2.1 * fk);
        float lean = 0.75 * (x0 - vp.x) / (0.5 - vp.y);
        float lo = k == 0 ? 0.06 : k == 1 ? 0.24 : k == 2 ? 0.26 : k == 3 ? 0.0 : 0.06;
        float hi = k == 0 ? 1.15 : k == 1 ? 0.90 : k == 2 ? 1.3 : k == 3 ? 1.25 : 1.1;
        float cx = x0 + lean * (y - 0.5) + (0.16 + 0.06 * fract(fk * 0.7)) * sin(2.4 * y + 1.7 * fk + 0.045 * t)
            + 0.30 * (field(float2(0.9 * y + 3.0 * fk, 0.010 * t + fk)) - 0.5)
            + (0.020 + 0.022 * storm) * sin(6.0 * y - 0.34 * t + 2.3 * fk) * smoothstep(0.1, 0.5, y);
        float w = (k == 3 ? 0.25 : 0.085 + 0.05 * fract(fk * 0.37)) * (0.65 + 0.7 * y);
        float sd = (k == 2 || k == 4) ? -1.0 : 1.0;
        float d = sd * (X - cx) / w;
        float prof = (d < 0.0 ? exp(-d * d * 2.4) : exp(-d * d * 0.55)) + 0.45 * exp(-d * d * 7.0);
        float soft = exp(-d * d * 0.12);
        float ray = 0.62 + 0.38 * smoothstep(0.2, 0.8, noise(float2(70.0 * angR - 0.09 * t, 0.8 * y + fk - 0.02 * t)))
                         * (0.50 + 0.50 * noise(float2(170.0 * angR + 3.0 + 0.13 * t, 1.3 * y)));
        float lo2 = lo + 0.10 * (field(float2(2.0 * X + 4.0 * fk, 0.008 * t)) - 0.5);
        float h = y - lo2;
        ray = mix(ray, 1.0, smoothstep(0.30, 0.75, h));
        float env = pow(smoothstep(0.0, 0.26, h + 0.04 * (noise(float2(14.0 * X, fk)) - 0.5)), 1.3)
                  * (0.55 + 0.45 * exp(-max(h, 0.0) / 0.30)) * (1.0 - smoothstep(hi - 0.45, hi + 0.05, y));
        float hot = 0.45 + 0.85 * smoothstep(0.30, 0.75, field(float2(1.5 * y - 0.04 * t + 5.0 * fk, 0.010 * t + 2.0 * fk)));
        float breathe = 0.72 + 0.28 * smoothstep(0.2, 0.8, noise(float2(0.05 * t + 3.7 * fk, fk)));
        float surge = sat(0.5 + 0.5 * sin(4.2 * y + 0.9 * X - (0.16 + 0.05 * fk) * t + 2.7 * fk));
        surge *= surge * surge;
        hot *= 0.78 + 0.55 * surge * (0.4 + 0.6 * storm);

        float3 tint;
        if (k == 3) {
            tint = mix(coral, pink, smoothstep(0.12, 0.40, y));
            tint = mix(tint, green, clamp(0.80 * smoothstep(0.3, 1.6, d) + 1.0 - smoothstep(lo, lo + 0.26, y), 0.0, 1.0));
            tint = mix(tint, float3(0.80, 0.15, 0.85), 0.5 * smoothstep(0.78, 1.1, y));
        } else if (k == 1) {
            tint = mix(teal, violet, smoothstep(lo + 0.05, lo + 0.35, y));
        } else {
            tint = mix(green, teal, smoothstep(lo + 0.25, hi, y));
            if (k == 0) tint = mix(tint, violet, 0.35 * smoothstep(0.7, 1.0, y));
        }
        float hueA = fract(0.0035 * t + 0.27 * fk + 0.10 * y);
        float3 shade = hueA < 0.34 ? mix(green, auCyan, hueA * 2.94)
                     : hueA < 0.67 ? mix(auCyan, auBlue, (hueA - 0.34) * 3.03)
                                   : mix(auBlue, green, (hueA - 0.67) * 3.03);
        float drift2 = smoothstep(0.15, 0.85, noise(float2(0.006 * t + 1.3 * fk, 4.0 + fk)));
        tint = mix(tint, shade, (k == 3 ? 0.30 : 0.45 + 0.40 * drift2));
        if (k != 3) tint = mix(tint, float3(0.80, 0.10, 0.22), 0.50 * smoothstep(0.35, 0.90, h));
        tint = mix(tint, lime, 0.40 * (1.0 - smoothstep(0.02, 0.14, h)));
        tint = mix(tint, float3(0.72, 0.18, 0.85), 0.35 * (1.0 - smoothstep(0.0, 0.07, h)));
        float gain = k == 1 ? 0.42 : k == 3 ? 1.55 : k == 2 ? 0.9 : 1.0;
        acc += 1.15 * tint * (prof * ray + (k == 3 ? 0.10 : 0.22) * soft) * env * hot * breathe * gain * (0.82 + 0.30 * storm);
    }
    acc *= (0.30 + 0.70 * smoothstep(0.0, 0.22, y)) * (1.0 - 0.45 * smoothstep(0.90, 1.0, y));
    c += float3(0.025, 0.065, 0.035) * exp(-pow((y - 0.07) / 0.05, 2.0));
    // soft highlight roll-off: overlaps glow, cores go pale instead of clipping
    float3 glow = 1.0 - exp(-1.7 * acc);
    glow += float3(0.9, 1.0, 0.95) * 0.22 * smoothstep(1.1, 2.4, max(acc.r, max(acc.g, acc.b)));
    float cover = min(1.0, max(glow.r, max(glow.g, glow.b)));
    c = c * (1.0 - 0.75 * cover) + glow * 0.92;

    // the land: rolling hills that catch a little of the light, and a spruce line in front
    float edgeW = 1.4 / res.y;
    float ridge = 0.055 + 0.120 * noise(float2(2.1 * X + 2.0, 7.0)) + 0.045 * noise(float2(4.7 * X, 2.0)) + 0.010 * noise(float2(13.0 * X, 4.0));
    float gnd = 0.032 + 0.020 * noise(float2(1.9 * X, 11.0));
    float trees = gnd, cw = 1.0 / 40.0, ci = floor(X / cw);
    float stand = 0.35 + 0.65 * smoothstep(0.22, 0.60, noise(float2(1.1 * X + 0.5, 5.0)));
    for (int j = -1; j <= 1; j++) {
        float id = ci + float(j);
        float th = (0.035 + 0.085 * pow(hash(float2(id, 3.7)), 1.4)) * stand * step(0.12, hash(float2(id, 9.1)));
        float tx = (id + 0.5 + 0.7 * (hash(float2(id, 1.3)) - 0.5)) * cw;
        float u = abs(X - tx) / (0.24 * th + 0.0015);
        float tier = 0.10 * th * abs(fract(7.0 * (y - gnd) / max(th, 0.001)) - 0.5);
        trees = max(trees, gnd + th * (1.0 - u) - tier);
    }
    float onRidge = 1.0 - smoothstep(ridge - edgeW, ridge + edgeW, y);
    float onTrees = 1.0 - smoothstep(trees - edgeW, trees + edgeW, y);
    float3 hill = float3(0.020, 0.027, 0.046) + 0.20 * glow * float3(0.30, 0.50, 0.46) * smoothstep(ridge - 0.06, ridge, y);
    c = mix(c, hill, onRidge * 0.90);
    c = mix(c, float3(0.004, 0.006, 0.011), onTrees);

    float vignette = length((uv - 0.5) * float2(res.x / res.y, 1.0));
    c *= 1.0 - 0.20 * smoothstep(0.6, 1.3, vignette);
    float dither = (hash(1.7 * pixel * scale + 31.0) - 0.5) * 1.6 / 255.0;
    return half4(half3(c + dither), 1.0h);
}

inline float3 mistVeil(float2 p, float t, float2 at, float2 r, float3 tint, float k) {
    float2 d = (p - at - 0.05 * float2(sin(0.010 * t + k), cos(0.008 * t + 2.0 * k))) / r;
    return tint * exp(-dot(d, d));
}

/// The ethereal sky (VibeVory's design): no curtains or land, the aurora as soft veils of mist
/// drifting over a dim night, with cloud texture and a little grain. Same arguments as auroraSky.
[[ stitchable ]] half4 auroraMist(float2 position, half4 color, float2 size, float scale, float t) {
    float2 res = size;
    float2 pixel = float2(position.x, size.y - position.y);   // y up
    float2 uv = pixel / res;
    float W = res.x / res.y;
    float2 p = float2(uv.x * W, uv.y);

    // dim night: a little lighter overhead
    float3 c = mix(float3(0.051, 0.055, 0.110), float3(0.078, 0.102, 0.172), smoothstep(0.0, 1.0, uv.y));

    // slow domain-warped clouds, so the veils have texture instead of being flat glows
    float s = 0.012 * t;
    float2 q = float2(field(1.1 * p + float2(s, 0.3)), field(1.1 * p + float2(5.2, -0.8 * s)));
    float cloud = field(1.7 * p + 1.6 * q + float2(0.6 * s, -0.3 * s));
    float wisps = smoothstep(0.25, 0.85, cloud);

    // the veils: where each colour sits, drifting a little
    float3 acc = float3(0);
    acc += mistVeil(p, t, float2(0.35 * W, 1.02), float2(0.55 * W, 0.30), float3(0.43, 0.90, 0.78), 0.0) * 0.55;  // teal
    acc += mistVeil(p, t, float2(0.78 * W, 1.05), float2(0.42 * W, 0.34), float3(0.59, 0.47, 1.00), 1.0) * 0.55;  // violet
    acc += mistVeil(p, t, float2(0.45 * W, 0.55), float2(0.50 * W, 0.30), float3(0.47, 0.59, 1.00), 2.0) * 0.22;  // blue
    acc += mistVeil(p, t, float2(0.80 * W, 0.20), float2(0.35 * W, 0.25), float3(0.94, 0.59, 0.75), 3.0) * 0.22;  // rose
    acc += mistVeil(p, t, float2(0.05 * W, 0.18), float2(0.30 * W, 0.22), float3(0.35, 0.78, 0.82), 4.0) * 0.16;  // cyan
    acc *= 0.45 + 0.85 * wisps;
    // a slow breath across the whole sky
    acc *= 0.85 + 0.15 * sin(0.03 * t);

    c = 1.0 - (1.0 - c) * (1.0 - 0.55 * acc);   // screen
    c += 0.025 * (cloud - 0.5) * float3(0.85, 0.88, 1.0);
    float grain = (hash(1.7 * pixel * scale + floor(t * 12.0)) - 0.5) * 5.0 / 255.0;
    return half4(half3(c + grain), 1.0h);
}
