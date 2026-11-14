// Space skies: the Milky Way and a nebula, as SwiftUI `colorEffect`s.
// Ported from the mockup Dev picked (claude_hermes/mockups/space-sky.html, scenes A and C).
//
// The nebula is split in two so it stays cheap: its clouds are soft and drift very slowly, so
// `nebulaClouds` is drawn at an eighth of the window's size and a few frames a second, and only the
// sharp, twinkling stars (`spaceStars`, a few hashes per pixel) run at the normal size and rate.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace space {

inline float hash(float2 p) {
    float3 v = fract(float3(p.x, p.y, p.x) * 0.1031);
    v += dot(v, v.yzx + 33.33);
    return fract((v.x + v.y) * v.z);
}

inline float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 q = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), q.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), q.x), q.y);
}

inline float fbm(float2 p) {
    float s = 0.0, a = 0.5;
    const float2x2 m = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
    for (int i = 0; i < 5; i++) { s += a * noise(p); p = m * p * 2.03; a *= 0.5; }
    return s;
}

/// One layer of stars. `pt` is in window points, so stars keep their size at any render scale.
inline float3 stars(float2 pt, float cell, float density, float bright, float t) {
    float2 g = pt / cell, c = floor(g), f = fract(g) - 0.5;
    float h = hash(c);
    float2 off = 0.35 * (float2(hash(c + 7.1), hash(c + 3.3)) - 0.5);
    float s = step(1.0 - density, h) * smoothstep(0.22, 0.0, length(f - off));
    float tw = 0.65 + 0.35 * sin(t * (0.7 + 2.0 * hash(c + 1.7)) + 6.28 * h);
    float3 tint = mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.86, 0.72), hash(c + 9.2));
    return tint * s * tw * bright * (0.35 + 0.65 * fract(h * 91.0));
}

inline float3 starfield(float2 pt, float boost, float t) {
    return stars(pt, 2.2, 0.05 * boost, 0.55, t)
         + stars(pt + 31.0, 4.5, 0.035, 0.9, t)
         + stars(pt + 77.0, 9.0, 0.02, 1.4, t);
}

inline float vignette(float2 uv) {
    return 0.75 + 0.25 * smoothstep(1.25, 0.3, length(uv - 0.5) * 1.4);
}

} // namespace space

using namespace space;

/// position: SwiftUI position (y down) in the drawn layer. size: that layer's size.
/// down: how many window points one layer point covers. t: seconds.
[[ stitchable ]] half4 milkyWaySky(float2 position, half4 color, float2 size, float down, float t) {
    float2 pixel = float2(position.x, size.y - position.y);   // y up
    float2 uv = pixel / size;
    float A = size.x / size.y;
    float2 p = float2(uv.x * A, uv.y);
    float3 c = mix(float3(0.010, 0.012, 0.030), float3(0.020, 0.024, 0.060), uv.y);

    // the band, along a diagonal, drifting very slowly
    float ang = -0.42;
    float2x2 r = float2x2(float2(cos(ang), -sin(ang)), float2(sin(ang), cos(ang)));
    float2 b = r * (p - float2(A * 0.5, 0.5));
    b.x += t * 0.004;
    float w = 0.20 + 0.05 * sin(b.x * 2.3);
    float d = b.y + 0.05 * (fbm(b * 3.0) - 0.5);
    float band = exp(-d * d / (w * w));
    float cloud = fbm(b * float2(3.0, 6.0) + float2(0, 1.3));
    float cx = b.x + 0.15;
    float core = exp(-cx * cx * 3.0);
    float3 glow = mix(float3(0.28, 0.30, 0.55), float3(0.95, 0.78, 0.62), core * band);
    float dust = smoothstep(0.42, 0.75, fbm(b * float2(5.0, 11.0) + 4.0)) * exp(-d * d / (w * w * 0.25));
    c += glow * band * (0.25 + 0.75 * cloud) * 0.55 * (1.0 - 0.85 * dust);
    c += float3(0.45, 0.38, 0.75) * exp(-d * d / (w * w * 6.0)) * 0.06;
    c += starfield(position * down, 1.0 + 3.0 * band, t) * (1.0 - 0.7 * dust);

    c *= vignette(uv);
    c += (hash(pixel + fract(t)) - 0.5) / 255.0;   // grain, so the gradients don't band
    return half4(half3(c), 1.0);
}

/// The nebula's clouds only (no stars): drawn small and slow, see the top of this file.
[[ stitchable ]] half4 nebulaClouds(float2 position, half4 color, float2 size, float down, float t) {
    float2 pixel = float2(position.x, size.y - position.y);
    float2 uv = pixel / size;
    float A = size.x / size.y;
    float2 p = float2(uv.x * A, uv.y) * 1.6;
    float3 c = float3(0.010, 0.010, 0.028);

    float2 drift = float2(t * 0.006, -t * 0.003);
    float2 w = float2(fbm(p + drift), fbm(p + float2(5.2, 1.3) - drift));
    float n = fbm(p + 2.2 * w + drift * 0.5);
    float m = fbm(p * 1.7 - 1.5 * w + 3.0);
    const float3 violet = float3(0.42, 0.24, 0.85), magenta = float3(0.80, 0.25, 0.55), teal = float3(0.10, 0.45, 0.60);
    float3 neb = mix(violet, magenta, smoothstep(0.35, 0.75, m));
    neb = mix(neb, teal, smoothstep(0.55, 0.85, w.x));
    float dens = smoothstep(0.35, 0.9, n);
    c += neb * dens * 0.55 + float3(0.9, 0.75, 1.0) * pow(dens, 4.0) * 0.25;
    float dark = smoothstep(0.55, 0.8, fbm(p * 3.0 + w * 2.0 + 7.0));
    c *= 1.0 - 0.55 * dark * dens;

    c *= vignette(uv);
    return half4(half3(c), 1.0);
}

/// Stars alone on black, laid over the nebula's clouds with plus-lighter blending.
[[ stitchable ]] half4 spaceStars(float2 position, half4 color, float2 size, float down, float t) {
    return half4(half3(starfield(position * down, 1.0, t) * 0.85), 1.0);
}
