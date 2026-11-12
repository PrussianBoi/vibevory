// Sunset: Zephyr's pink sunset sky, frozen at one moment.
// Ported from Zephyr's sky shader (https://github.com/Peteryhs/zephyr, MIT, (c) 2026 Peteryhs),
// sky/shaders.js, as a SwiftUI `colorEffect`. The CPU frame evaluator (sky/engine.js) was run once
// in Node for Toronto, 2026-07-10 21:06 local (sun -1.70 deg, just below the horizon, where the
// "sunset pink" grade peaks), weather code 1 (mainly clear, 25% cloud); its uniforms are baked
// in below. Motion (warped cloud field, cirrus strands, drift) still runs on `t`.
//
// Stages kept from the 20-stage pipeline: warped cloud field + 4-stop gradient, polarisation and
// aureole, texture modulation, cloud tint, cirrus veil, airmass whitening, sheet, sun glow,
// vignette, grain + dither. Stages dropped because they are zero at this moment: purple light,
// crepuscular shadows, cloud lighting (thin/back), night milk, haze, fog, halo, sun dogs, corona,
// rays, precipitation, aurora, finishing LUT, night floor.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace sunset {

// ---- frozen frame (engine.js evaluate at the moment above) ----
constant float3 kC0 = float3(0.3775, 0.4080, 0.4834);      // zenith: slate blue
constant float3 kC1 = float3(0.5855, 0.5072, 0.7700);      // lavender
constant float3 kC2 = float3(0.9354, 0.6219, 0.6946);      // pink
constant float3 kC3 = float3(0.9986, 0.4841, 0.5775);      // horizon: coral pink
constant float2 kGlowPos = float2(0.8400, 0.04899);
constant float3 kGlowCol = float3(0.9786, 0.2308, 0.00757);
constant float kGlow = 0.11168;
constant float kGlowSize = 1.5;
constant float kDensity = 0.44953;
constant float kWarp = 1.7;
constant float kGrain = 0.018;
constant float2 kDrift = float2(0.63899, 0.23257);
constant float3 kMilk = float3(0.51985, 0.52452, 0.53153);
constant float kDeck = 0.001464;
constant float kPuff = 0.26000;
constant float kSquash = 0.85579;
constant float3 kTint = float3(1.00198, 0.99929, 0.99848);
constant float3 kTintHi = float3(1.22426, 0.91915, 0.82809);
constant float3 kSun = float3(0.8400, 0.04899, -1.70044);  // screen x, y, altitude (deg)
constant float kPolar = 0.49972;
constant float2 kAureole = float2(0.19989, 16.0);
constant float kWhiten = 0.008051;
constant float kLitZ = 0.44485;
// cirrus look: angle (rad), variance (rad), fiber, opacity / bias, evolution, break depth, grain
constant float4 kCirA = float4(0.261799, 0.139626, 1.1, 0.53);
constant float4 kCirB = float4(-0.17, 0.008, 0.44, 2.8);
constant float kSkySpeed = 2.5;     // Zephyr sky-time units per real second
constant float kDegPerRad = 57.29577951308232;
constant float kRadPerDeg = 0.017453292519943295;

inline float sat(float v) { return clamp(v, 0.0, 1.0); }
inline float lum(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }
inline float3 screenRGB(float3 c, float3 contribution) { return c + contribution * (1.0 - c); }

inline float hash(float2 p) {
    float3 v = fract(float3(p.x, p.y, p.x) * 0.1031);
    v += dot(v, v.yzx + 33.33);
    return fract((v.x + v.y) * v.z);
}

inline float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 q = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(mix(hash(i), hash(i + float2(1.0, 0.0)), q.x),
               mix(hash(i + float2(0.0, 1.0)), hash(i + float2(1.0, 1.0)), q.x), q.y);
}

inline float2x2 turn(float angle) {
    float c = cos(angle), s = sin(angle);
    return float2x2(float2(c, s), float2(-s, c));
}

inline float field(float2 p) {
    float total = 0.0, amplitude = 0.52;
    const float2x2 m = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
    for (int i = 0; i < 4; i++) { total += amplitude * noise(p); p = m * p * 1.9; amplitude *= 0.5; }
    return total;
}

} // namespace sunset

using namespace sunset;

/// position: SwiftUI pixel position (y down). size: view size in the same units.
/// scale: pixels per point of the rendered layer (unused). t: seconds.
[[ stitchable ]] half4 sunsetSky(float2 position, half4 color, float2 size, float scale, float t) {
    float2 res = max(size, float2(1.0));
    float2 pixel = float2(position.x, res.y - position.y);   // GL convention: y up
    float2 uv = pixel / res;
    float det = max(1.0, min(res.y, mix(res.x, res.y, 0.15)));   // engine detUnit(w, h, 1, 0.15)
    float2 P = (pixel - 0.5 * res) / det, K = res / det;
    float T = kSkySpeed * t;

    // 1. warped cloud field and the four-stop gradient
    float2 A = P - 0.018 * T * kDrift;
    float2 q = float2(field(A + T * float2(0.010, 0.006)),
                      field(A + float2(5.2, 1.3) - T * float2(0.007, 0.009)));
    float2 r = float2(field(1.4 * A + 1.1 * kWarp * q + float2(1.7, 9.2) + T * float2(0.0035, -0.0025)),
                      field(1.4 * A + 1.1 * kWarp * q + float2(8.3, 2.8) - T * float2(0.0025, 0.0035)));
    float f = mix(field(1.1 * A + 0.8 * kWarp * r), 0.5, 0.35);
    float g = sat(uv.y + (f - 0.5) * (0.18 + 0.6 * kDensity) * (0.88 + 0.3 * uv.y));
    float gm = pow(g, kSquash);
    float3 c = mix(kC3, kC2, smoothstep(0.0, 0.45, gm));
    c = mix(c, kC1, smoothstep(0.32, 0.78, gm));
    c = mix(c, kC0, smoothstep(0.62, 1.0, gm));

    // 2. polarisation and the aureole around the (just set) sun
    float sky = 1.0 - smoothstep(0.47, 0.78, f);
    float a1 = (kSun.z + (112.5 * (uv.y - 0.10) - kSun.z) * K.y) * kRadPerDeg, a2 = kSun.z * kRadPerDeg;
    float az = ((uv.x - kSun.x) * K.x * 112.5) * kRadPerDeg;
    float cosine = clamp(sin(a1) * sin(a2) + cos(a1) * cos(a2) * cos(az), -1.0, 1.0);
    float angle = acos(cosine) * kDegPerRad;
    float purity = (1.0 - cosine * cosine) / (1.0 + cosine * cosine), pol = purity * kPolar * sky;
    float lc = lum(c);
    c = max(float3(0.0), mix(c, float3(lc) + (c - lc) * 1.25, pol)) * (1.0 - 0.45 * pol);
    float broad = cosine >= 0.0 ? cosine * cosine : 0.0;
    float aureole = kAureole.x * (0.35 * broad + 0.65 * exp(-angle / max(1.0, kAureole.y))) * sky;
    float3 illum = mix(float3(1.0), kGlowCol, 0.5);
    c = mix(c, illum * lum(c), 0.7 * aureole);
    c = screenRGB(c, 0.55 * aureole * illum);

    // 4-5. cloud texture and tint
    c *= 1.0 + (f - 0.5) * (0.05 + 0.13 * min(kDensity, 1.7) + 0.7 * kDeck) * (0.85 + 0.45 * uv.y);
    c *= mix(float3(1.0), kTint, smoothstep(0.47, 0.78, f));

    // 7. cirrus veil
    {
        float2 Pa = P - 0.007 * T * kDrift;
        float dv = noise(0.4 * Pa + float2(19.3, 4.7)) - 0.5;
        float alpha = kCirA.x + 8.0 * dv * dv * dv * kCirA.y;
        float2 R = turn(-alpha) * P - 0.007 * T * kDrift;
        float ev = T * kCirB.y;
        float wobble = noise(float2(2.6 * R.x, 4.0 * R.y) + float2(11.1, 6.3)) - 0.5;
        float strand = noise(float2(0.7 * R.x, 12.0 * kCirA.z * R.y + 1.5 * wobble) + float2(7.7, 2.2 + ev));
        float fine = noise(float2(1.6 * R.x, 26.0 * kCirA.z * R.y + 3.2 * wobble) + float2(3.3, 9.1 - 1.7 * ev));
        float bank = noise(float2(0.35 * R.x, 1.5 * R.y) + float2(3.1, 8.4) + T * float2(0.008, 0.005));
        float veil = smoothstep(0.35, 0.95, 0.65 * strand + 0.35 * fine)
                   * smoothstep(0.25 - kCirB.x, 0.85 - kCirB.x, bank) * smoothstep(0.10, 0.30, uv.y);
        float2 cellP = 6.0 * kCirB.w * R;
        const float2x2 m = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
        float cell = 0.55 * noise(cellP + 0.9 * wobble + float2(4.2, 1.9 + 0.6 * ev))
                   + 0.30 * noise(2.1 * (m * cellP) + float2(9.4, 3.3 - ev))
                   + 0.15 * noise(3.7 * cellP + float2(1.3, 7.9));
        veil *= (1.0 - kCirB.z) + kCirB.z * smoothstep(0.32, 0.75, cell);
        float3 material = min(kMilk * 1.22 * kTintHi, float3(1.0));
        float3 overlay = mix(2.0 * c * material, 1.0 - 2.0 * (1.0 - c) * (1.0 - material), step(float3(0.5), c));
        c = mix(c, overlay, kPuff * veil * kCirA.w);
    }

    // 9. airmass whitening toward the horizon
    float alt = 112.5 * (uv.y - 0.10);
    float z = 0.5 * (alt + sqrt(alt * alt + 4.0)) + 1.0;
    float airMass = 1.0 / (sin(z * kRadPerDeg) + 0.15 * pow(z + 3.885, -1.253));
    float whiteAmount = 1.0 - exp(-kWhiten * airMass);
    float lowSun = 1.0 - smoothstep(5.0, 25.0, kSun.z);
    illum = mix(float3(1.0), kGlowCol, 0.6 * lowSun);
    illum = mix(illum, illum * float3(0.88, 0.93, 1.14), kLitZ);
    c = mix(c, illum * mix(lum(c), 0.92, 0.6), whiteAmount);

    // 11. sheet
    float sheet = smoothstep(0.45, 0.95, r.y) * kDensity;
    c = mix(c, 1.05 * c + 0.015, 0.22 * sheet);

    // 13. sun glow
    float2 B = (uv - kGlowPos) * K;
    float d2 = dot(B, B) / (kGlowSize * kGlowSize);
    c = screenRGB(c, kGlowCol * kGlow * (0.60 * exp(-55.0 * d2) + 0.25 * exp(-11.0 * d2)));

    // 20. vignette, grain, dither
    float vignette = length((uv - 0.5) * float2(res.x / res.y, 1.0));
    c *= 1.0 - 0.20 * smoothstep(0.6, 1.3, vignette);
    float grain = ((hash(pixel) + hash(pixel + 17.13) + hash(pixel + 41.77)) / 3.0 - 0.5) * kGrain * 1.7;
    float dither = (hash(1.7 * pixel + 31.0) - 0.5) * 1.6 / 255.0;
    c = saturate(c + grain + dither);
    return half4(half3(c), 1.0h);
}
