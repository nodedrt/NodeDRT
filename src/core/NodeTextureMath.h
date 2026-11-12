// =============================================================================
//  NODE_DRT — Texture (Grain + Halation): per-pixel maths shared by CPU and GPU
// -----------------------------------------------------------------------------
//  This header compiles as C++ (the CPU path, NodeTexture.cpp) and as Metal
//  (baked together with NodeTexture.metal into gen/texture_metal_src.h), so the
//  two paths run the very same formulas. Both are IEEE single precision with
//  fast-math off.
//
//  The texture stage runs BEFORE the display transform, on the camera log
//  image: decode the log curve to linear light (the same curves as the DCTL),
//  add halation and grain, encode back. Only the change is re-encoded
//  (out = in + enc(new) - enc(old)), so with both effects off, or wherever an
//  effect adds nothing, the picture is passed through bit for bit.
//
//  Grain: spektrafilm's grain model, measured (see the grain section). Halation (unused since 1.3) was modelled by measurement on film renders (grain:
//  per-channel strength against density, spatial spectrum per gauge, channel
//  correlation; halation: source curve, radial kernel and per-layer weights).
// =============================================================================
#pragma once

#ifdef __METAL_VERSION__
#define TX_FN inline
#define TX_CONST constant
#define TX_LOG2(x) metal::log2(x)
#define TX_EXP2(x) metal::exp2(x)
#define TX_LOG(x) metal::log(x)
#define TX_EXP(x) metal::exp(x)
#define TX_LOG10(x) metal::log10(x)
#define TX_POW(a, b) metal::pow(a, b)
#define TX_SQRT(x) metal::sqrt(x)
#define TX_COS(x) metal::cos(x)
#define TX_FLOOR(x) metal::floor(x)
#define TX_MAX(a, b) metal::fmax(a, b)
#define TX_MIN(a, b) metal::fmin(a, b)
#else
#include <cmath>
#define TX_FN static inline
#define TX_CONST static const
#define TX_LOG2(x) std::log2(x)
#define TX_EXP2(x) std::exp2(x)
#define TX_LOG(x) std::log(x)
#define TX_EXP(x) std::exp(x)
#define TX_LOG10(x) std::log10(x)
#define TX_POW(a, b) std::pow(a, b)
#define TX_SQRT(x) std::sqrt(x)
#define TX_COS(x) std::cos(x)
#define TX_FLOOR(x) std::floor(x)
#define TX_MAX(a, b) std::fmax(a, b)
#define TX_MIN(a, b) std::fmin(a, b)
#endif

// ---- parameters handed to every texture kernel (same layout CPU / GPU) --------
struct TexArgs {
    int W, H;            // full frame
    int W2, H2;          // halation grid (half resolution for large frames)
    int halfRes;          // 1 = halation evaluated at half resolution
    int halR;            // halation kernel radius on its grid
    int grR;             // grain kernel radius
    int oetf;            // input log curve (DCTL in_oetf)
    int gamut;           // input gamut (DCTL in_gamut)
    int halOn, grOn;
    unsigned int seed;   // grain pattern (per frame when animated)
    int srcRow, dstRow;  // row strides in floats
    int halSoftR;        // radius of the halo softening (0 = none)
    int grGauge;         // 0 65mm, 1 35mm, 2 16mm, 3 8mm
    float halS, halThr, kw0, kw1, kw2;   // halation strength, threshold, per-channel weights
    float halNorm[6];                    // weight of each separable term
    float grScale, grSat, grSh, grMd, grHi;
    float Yr, Yg, Yb;                    // luminance row of the input gamut
};

TX_FN float tx_clamp(float x, float a, float b) { return TX_MIN(TX_MAX(x, a), b); }
TX_FN float tx_smooth(float e0, float e1, float x)
{
    float t = tx_clamp((x - e0) / TX_MAX(e1 - e0, 1e-6f), 0.0f, 1.0f);
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

// ---- log curves: decode = the DCTL's linearize(), encode = its exact inverse ---
TX_FN float tx_decode(int tf, float x)
{
    if (tf == 1) return x <= 0.02740668f ? x / 10.44426855f : TX_EXP2(x / 0.07329248f - 7.0f) - 0.0075f;
    if (tf == 2) return x < 0.075f ? (x - 0.075f) / 16.184376489665897f
                                   : TX_EXP((x - 0.5520126568606655f) / 0.09232902596577353f) - 0.0057048244042473785f;
    if (tf == 3) return x <= 0.155251141552511f ? (x - 0.0729055341958355f) / 10.5402377416545f
                                                : TX_EXP2(x * 17.52f - 9.72f);
    if (tf == 4) return x < 5.367655f * 0.010591f + 0.092809f ? (x - 0.092809f) / 5.367655f
                                                               : (TX_POW(10.0f, (x - 0.385537f) / 0.247190f) - 0.052272f) / 5.555556f;
    if (tf == 5) return x < -0.7774983977293537f ? x * 0.3033266726886969f - 0.7774983977293537f
                                                 : (TX_EXP2(14.0f * (x - 0.09286412512218964f) / 0.9071358748778103f + 6.0f) - 64.0f) / 2231.8263090676883f;
    if (tf == 6) return x < 0.0f ? (x / 15.1927f) - 0.01f : (TX_POW(10.0f, x / 0.224282f) - 1.0f) / 155.975327f - 0.01f;
    if (tf == 7) return x < 0.181f ? (x - 0.125f) / 5.6f : TX_POW(10.0f, (x - 0.598206f) / 0.241514f) - 0.00873f;
    if (tf == 8) return x < 171.2102946929f / 1023.0f ? (x * 1023.0f - 95.0f) * 0.01125f / (171.2102946929f - 95.0f)
                                                      : (TX_POW(10.0f, (x * 1023.0f - 420.0f) / 261.5f) * (0.18f + 0.01f) - 0.01f);
    if (tf == 9) return x < 0.100686685370811f ? (x - 0.092864f) / 8.799461f
                                               : (TX_POW(10.0f, (x - 0.384316f) / 0.245281f) / 5.555556f - 0.064829f / 5.555556f);
    return x;
}

TX_FN float tx_encode(int tf, float l)
{
    if (tf == 1) return l <= 0.00262409f ? l * 10.44426855f : (TX_LOG2(l + 0.0075f) + 7.0f) * 0.07329248f;
    if (tf == 2) return l < 0.0f ? l * 16.184376489665897f + 0.075f
                                 : 0.09232902596577353f * TX_LOG(l + 0.0057048244042473785f) + 0.5520126568606655f;
    if (tf == 3) return l <= 0.0078125f ? l * 10.5402377416545f + 0.0729055341958355f : (TX_LOG2(l) + 9.72f) / 17.52f;
    if (tf == 4) return l < 0.010591f ? 5.367655f * l + 0.092809f : 0.247190f * TX_LOG10(5.555556f * l + 0.052272f) + 0.385537f;
    if (tf == 5) {
        const float v = 2231.8263090676883f * l + 64.0f;
        return v > 1e-30f ? (TX_LOG2(v) - 6.0f) * 0.9071358748778103f / 14.0f + 0.09286412512218964f
                          : (l + 0.7774983977293537f) / 0.3033266726886969f;
    }
    if (tf == 6) return l < -0.01f ? (l + 0.01f) * 15.1927f : 0.224282f * TX_LOG10((l + 0.01f) * 155.975327f + 1.0f);
    if (tf == 7) return l < 0.01f ? 5.6f * l + 0.125f : 0.241514f * TX_LOG10(l + 0.00873f) + 0.598206f;
    if (tf == 8) return l < 0.01125f ? (l * (171.2102946929f - 95.0f) / 0.01125f + 95.0f) / 1023.0f
                                     : (420.0f + TX_LOG10((l + 0.01f) / 0.19f) * 261.5f) / 1023.0f;
    if (tf == 9) return l < 0.000889f ? 8.799461f * l + 0.092864f : 0.245281f * TX_LOG10(5.555556f * l + 0.064829f) + 0.384316f;
    return l;
}

// DaVinci Intermediate, the domain the grain was measured in
TX_FN float tx_di_enc(float l) { return l <= 0.00262409f ? l * 10.44426855f : (TX_LOG2(TX_MAX(l + 0.0075f, 1e-10f)) + 7.0f) * 0.07329248f; }
TX_FN float tx_di_dec(float t) { return t <= 0.02740668f ? t / 10.44426855f : TX_EXP2(t / 0.07329248f - 7.0f) - 0.0075f; }

// ---- halation ---------------------------------------------------------------
// The halo is added in the measured addition domain T(l) = (l + eps)^p. Its
// source is the part of the picture above the film's halation threshold.
TX_CONST float HX_P = 0.36349345f;
TX_CONST float HX_EPS = 0.04821232f;
TX_CONST float HX_K[3] = {1.07395840f, 0.28207478f, 0.10016683f};
TX_CONST float HX_SK_DI[10] = {0.40f, 0.45f, 0.50f, 0.55f, 0.60f, 0.65f, 0.70f, 0.80f, 0.90f, 1.00f};
TX_CONST float HX_SK_V[10] = {0.00000000f, 0.04563354f, 0.08497251f, 0.12796855f, 0.24987521f,
                              0.54074709f, 0.99219322f, 1.05172038f, 1.08905872f, 1.12633244f};

TX_FN float tx_halT(float l) { return TX_POW(TX_MAX(l, 0.0f) + HX_EPS, HX_P); }
TX_FN float tx_halTi(float u) { return TX_POW(TX_MAX(u, 1e-9f), 1.0f / HX_P) - HX_EPS; }
TX_FN float tx_halSource(float Y, float shift)
{
    const float d = tx_di_enc(TX_MAX(Y, 0.0f)) - shift;
    if (d <= HX_SK_DI[0]) return 0.0f;
    for (int j = 1; j < 10; ++j)
        if (d <= HX_SK_DI[j]) {
            const float f = (d - HX_SK_DI[j - 1]) / (HX_SK_DI[j] - HX_SK_DI[j - 1]);
            return HX_SK_V[j - 1] + (HX_SK_V[j] - HX_SK_V[j - 1]) * f;
        }
    return HX_SK_V[9];
}
// adds `add` (>= 0) in the T domain; only the change is applied, so negative
// or untouched values keep their exact value.
TX_FN float tx_halAdd(float l, float add)
{
    if (add <= 0.0f) return l;
    const float t = tx_halT(l);
    return l + (tx_halTi(t + add) - tx_halTi(t));
}

// ---- grain ------------------------------------------------------------------
// GRAIN (Node DRT 1.3): measured on spektrafilm's grain model (Andrea Volpato,
// GPLv3 - particles per layer, Kodak Vision3 250D), at the pixel pitch of a UHD
// frame for each gauge: the grain of the negative's density, brought back to
// the DaVinci Intermediate code through the negative's own slope. Strength
// (std of the DI code) per channel against the channel's DI value; the three
// colour layers are independent (spektrafilm's layers do not correlate).
// Measured by tools/film/measure_grain.py; nothing comes from another product.
TX_CONST float GX_D[9] = {0.10f, 0.20f, 0.28f, 0.336f, 0.40f, 0.48f, 0.56f, 0.64f, 0.72f};
TX_CONST float GX_SIG[108] = {   // [gauge 65 / 35 / 16 / 8 mm][channel][density]
    0.0049f, 0.0052f, 0.0055f, 0.0055f, 0.0052f, 0.0050f, 0.0051f, 0.0052f, 0.0054f,   // 65mm R
    0.0046f, 0.0049f, 0.0052f, 0.0052f, 0.0051f, 0.0050f, 0.0049f, 0.0050f, 0.0051f,   // 65mm G
    0.0067f, 0.0073f, 0.0076f, 0.0076f, 0.0076f, 0.0075f, 0.0072f, 0.0073f, 0.0076f,   // 65mm B
    0.0091f, 0.0097f, 0.0103f, 0.0102f, 0.0097f, 0.0094f, 0.0094f, 0.0097f, 0.0100f,   // 35mm R
    0.0086f, 0.0092f, 0.0096f, 0.0097f, 0.0096f, 0.0092f, 0.0091f, 0.0092f, 0.0096f,   // 35mm G
    0.0124f, 0.0135f, 0.0141f, 0.0141f, 0.0142f, 0.0139f, 0.0133f, 0.0135f, 0.0140f,   // 35mm B
    0.0198f, 0.0213f, 0.0224f, 0.0222f, 0.0212f, 0.0205f, 0.0206f, 0.0213f, 0.0219f,   // 16mm R
    0.0188f, 0.0201f, 0.0210f, 0.0213f, 0.0209f, 0.0202f, 0.0199f, 0.0202f, 0.0210f,   // 16mm G
    0.0258f, 0.0283f, 0.0299f, 0.0301f, 0.0304f, 0.0300f, 0.0289f, 0.0292f, 0.0304f,   // 16mm B
    0.0332f, 0.0364f, 0.0394f, 0.0402f, 0.0394f, 0.0387f, 0.0392f, 0.0405f, 0.0414f,   // 8mm R
    0.0310f, 0.0339f, 0.0368f, 0.0384f, 0.0389f, 0.0383f, 0.0384f, 0.0389f, 0.0404f,   // 8mm G
    0.0361f, 0.0402f, 0.0436f, 0.0454f, 0.0474f, 0.0482f, 0.0474f, 0.0486f, 0.0509f,   // 8mm B
};

TX_FN float tx_grainSig(int g, int c, float d)
{
    const int o = (g * 3 + c) * 9;
    if (d <= GX_D[0]) return GX_SIG[o];
    for (int j = 1; j < 9; ++j)
        if (d <= GX_D[j]) {
            const float f = (d - GX_D[j - 1]) / (GX_D[j] - GX_D[j - 1]);
            return GX_SIG[o + j - 1] + (GX_SIG[o + j] - GX_SIG[o + j - 1]) * f;
        }
    return GX_SIG[o + 8];
}

TX_FN unsigned int tx_hash(unsigned int x, unsigned int y, unsigned int s)
{
    unsigned int h = x * 0x8da6b343u ^ y * 0xd8163841u ^ s * 0xcb1ab31fu;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15; h *= 0x846ca68bu; h ^= h >> 16;
    return h;
}
TX_FN float tx_gauss(int x, int y, unsigned int seed)
{
    const unsigned int a = tx_hash((unsigned int)(x + 65536), (unsigned int)(y + 65536), seed);
    const unsigned int b = tx_hash((unsigned int)(x + 65536), (unsigned int)(y + 65536), seed ^ 0x9e3779b9u);
    const float u1 = ((float)(a >> 8) + 0.5f) * (1.0f / 16777216.0f);
    const float u2 = (float)(b >> 8) * (1.0f / 16777216.0f);
    return TX_SQRT(-2.0f * TX_LOG(u1)) * TX_COS(6.28318530718f * u2);
}
TX_CONST unsigned int GX_CH_SEED = 0x632BE5ABu;

struct TxRGB { float r, g, b; };

// One pixel through the whole texture stage. c: decoded linear pixel; S0 its
// halation source, B the blurred source around it; z the three unit grain
// fields. Halation first (light spreading in the emulsion), grain on top.
TX_FN TxRGB tx_pixel(int halOn, float halS, float kw0, float kw1, float kw2, int grOn, int grGauge, float grScale, float grSat,
                     float grSh, float grMd, float grHi, float Yr, float Yg, float Yb, TxRGB c, float S0, float B,
                     float z0, float z1, float z2)
{
    if (halOn) {
        // only the light coming from brighter surroundings: a flat highlight
        // keeps its own colour, the halo spreads out of it.
        const float add = halS * TX_MAX(B - S0, 0.0f);
        c.r = tx_halAdd(c.r, kw0 * add);
        c.g = tx_halAdd(c.g, kw1 * add);
        c.b = tx_halAdd(c.b, kw2 * add);
    }
    if (grOn) {
        // independent layers, the colour control blends towards mono
        const float n0 = z0, n1 = z1, n2 = z2;
        const float zm = (n0 + n1 + n2) * 0.57735027f;   // 1/sqrt(3): unit variance
        const float Y = Yr * c.r + Yg * c.g + Yb * c.b;
        const float ev = TX_LOG2(TX_MAX(Y, 1e-10f) / 0.18f);
        const float wsh = 1.0f - tx_smooth(-4.0f, -1.0f, ev), whi = tx_smooth(1.0f, 4.0f, ev);
        const float f = grScale * (grSh * wsh + grHi * whi + grMd * TX_MAX(1.0f - wsh - whi, 0.0f));
        if (f > 0.0f) {
            const float dr = tx_di_enc(c.r), dg = tx_di_enc(c.g), db = tx_di_enc(c.b);
            c.r = tx_di_dec(dr + f * tx_grainSig(grGauge, 0, dr) * (zm + grSat * (n0 - zm)));
            c.g = tx_di_dec(dg + f * tx_grainSig(grGauge, 1, dg) * (zm + grSat * (n1 - zm)));
            c.b = tx_di_dec(db + f * tx_grainSig(grGauge, 2, db) * (zm + grSat * (n2 - zm)));
        }
    }
    return c;
}
