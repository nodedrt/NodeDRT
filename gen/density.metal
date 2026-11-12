#include <metal_stdlib>
using namespace metal;
#line 1 "NodeTextureMath.h"
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

#line 1 "NodeDensityMath.h"
// =============================================================================
//  NODE_DRT — Density Pro: per-pixel maths shared by CPU and GPU
// -----------------------------------------------------------------------------
//  Density by zone (shadows / midtones / highlights) and by colour (R Y G C B M),
//  taken from RELIEF (Samuel Drouin). The formulas are RELIEF's own: OKLab hue
//  windows, luminance zones in stops, a film-density move in OKLab, the tone
//  safety scale and the soft mask. Nothing in it is measured from another
//  product.
//
//  Like the Texture stage it runs BEFORE the display transform, on the camera
//  log image, in RELIEF's working space: DaVinci Wide Gamut / Intermediate. With
//  the default input (DWG / DaVinci Intermediate) the picture is used as is;
//  any other input is converted there and back, and only the change is
//  re-encoded, so an untouched pixel comes out bit for bit.
//
//  This header compiles as C++ (CPU path, NodeDensity.cpp) and as Metal (baked
//  with NodeDensity.metal into gen/density_metal_src.h): one set of formulas.
// =============================================================================


#ifdef __METAL_VERSION__
#define DP_FN inline
#define DP_CONST constant
#define DP_EXP2(x) metal::exp2(x)
#define DP_LOG2(x) metal::log2(x)
#define DP_SQRT(x) metal::sqrt(x)
#define DP_TANH(x) metal::tanh(x)
#define DP_FLOOR(x) metal::floor(x)
#define DP_FABS(x) metal::fabs(x)
#define DP_MAX(a, b) metal::fmax(a, b)
#define DP_MIN(a, b) metal::fmin(a, b)
#define DP_U32(x) as_type<uint>(x)
#define DP_F32(i) as_type<float>(i)
typedef uint dp_u32;
#define DP_REF thread float&
#else
#include <cmath>
#include <cstdint>
#include <cstring>
#define DP_FN static inline
#define DP_CONST static const
#define DP_EXP2(x) std::exp2(x)
#define DP_LOG2(x) std::log2(x)
#define DP_SQRT(x) std::sqrt(x)
#define DP_TANH(x) std::tanh(x)
#define DP_FLOOR(x) std::floor(x)
#define DP_FABS(x) std::fabs(x)
#define DP_MAX(a, b) std::fmax(a, b)
#define DP_MIN(a, b) std::fmin(a, b)
typedef uint32_t dp_u32;
#define DP_REF float&
static inline dp_u32 dp_bits(float x) { dp_u32 i; std::memcpy(&i, &x, 4); return i; }
static inline float dp_float(dp_u32 i) { float x; std::memcpy(&x, &i, 4); return x; }
#define DP_U32(x) dp_bits(x)
#define DP_F32(i) dp_float(i)
#endif

// ---- parameters handed to every Density Pro kernel (same layout CPU / GPU) ----
struct DensArgs {
    int W, H;            // frame
    int srcRow, dstRow;  // row strides in floats
    int oetf;            // input log curve (DCTL in_oetf)
    int direct;          // 1 = input already is DWG / DaVinci Intermediate: used as is
    int show;            // Show Mask
    int maskFocus;       // -1 every active slider, 0..5 a colour, 6..8 a zone, 9 zone map, 10 every active colour
    int blurR;           // box radius of the soft mask (3 box passes ~ gaussian), 0 = none
    int pad0, pad1, pad2;
    float mIn[9];        // input gamut -> DaVinci Wide Gamut (row major)
    float mOut[9];       // its inverse
    float zone[3];       // shadows, midtones, highlights density (-100..100)
    float hue[6];        // red, yellow, green, cyan, blue, magenta density (-100..100)
    float range[6];      // width of each colour window (0.1..4)
    float boost;         // Global Strength 0..100 (x1..x4)
    float focus;         // Saturation Focus 0..100
    float zpiv;          // Zones Pivot (stops)
    float zsoft;         // Zones Softness 0..1
    float lam;           // tone-safety scale of the zone sliders (computed on the host)
};

DP_CONST float DP_PIV = 0.336043f;   // DaVinci Intermediate code of 0.18

DP_FN float dp_clamp01(float x) { return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x); }
DP_FN float dp_sstep(float x, float e0, float e1) { float t = dp_clamp01((x - e0) / (e1 - e0)); return t * t * (3.0f - 2.0f * t); }
DP_FN float dp_ss5(float a, float b, float x) { float t = DP_MIN(DP_MAX((x - a) / (b - a), 0.0f), 1.0f); return t * t * t * (t * (6.0f * t - 15.0f) + 10.0f); }
DP_FN float dp_di2lin(float t) { return t <= 0.02740668f ? t / 10.44426855f : DP_EXP2(t / 0.07329248f - 7.0f) - 0.0075f; }
DP_FN float dp_lin2di(float x) { return x <= 0.00262409f ? x * 10.44426855f : (DP_LOG2(DP_MAX(x + 0.0075f, 1e-10f)) + 7.0f) * 0.07329248f; }

// cube root: bit trick + 3 Newton steps (relative error < 1e-6)
DP_FN float dp_cbrt_pos(float x)
{
    dp_u32 i = DP_U32(x);
    i = i / 3u + 709921077u;
    float y = DP_F32(i);
    y = (2.0f * y + x / (y * y)) * 0.333333333f;
    y = (2.0f * y + x / (y * y)) * 0.333333333f;
    return (2.0f * y + x / (y * y)) * 0.333333333f;
}
DP_FN float dp_cbrt(float x) { return x == 0.0f ? 0.0f : (x < 0.0f ? -dp_cbrt_pos(-x) : dp_cbrt_pos(x)); }

// atan2 in degrees (minimax polynomial, error < 0.01 degree)
DP_FN float dp_atan2deg(float y, float x)
{
    const float ax = DP_FABS(x), ay = DP_FABS(y), mx = DP_MAX(ax, ay);
    if (mx == 0.0f) return 0.0f;
    const float a = DP_MIN(ax, ay) / mx, s2 = a * a;
    float r = ((-0.0464964749f * s2 + 0.15931422f) * s2 - 0.327622764f) * s2 * a + a;
    if (ay > ax) r = 1.57079637f - r;
    if (x < 0.0f) r = 3.14159274f - r;
    if (y < 0.0f) r = -r;
    return r * 57.2957795f;
}
DP_FN float dp_wrap180(float d) { return d - 360.0f * DP_FLOOR((d + 180.0f) * (1.0f / 360.0f)); }

struct DpLab { float L, A, B; };
DP_FN DpLab dp_oklab(float l0, float l1, float l2)
{
    const float ol = dp_cbrt(0.4122214708f * l0 + 0.5363325363f * l1 + 0.0514459929f * l2);
    const float om = dp_cbrt(0.2119034982f * l0 + 0.6806995451f * l1 + 0.1073969566f * l2);
    const float os = dp_cbrt(0.0883024619f * l0 + 0.2817188376f * l1 + 0.6299787005f * l2);
    DpLab o;
    o.L = 0.2104542553f * ol + 0.7936177850f * om - 0.0040720468f * os;
    o.A = 1.9779984951f * ol - 2.4285922050f * om + 0.4505937099f * os;
    o.B = 0.0259040371f * ol + 0.7827717662f * om - 0.8086757660f * os;
    return o;
}
struct DpRGB { float r, g, b; };
DP_FN DpRGB dp_oklabInv(float L, float a, float b)
{
    const float l_ = L + 0.3963377774f * a + 0.2158037573f * b, m_ = L - 0.1055613458f * a - 0.0638541728f * b,
                s_ = L - 0.0894841775f * a - 1.2914855480f * b;
    const float l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_;
    DpRGB o;
    o.r = 4.0767416621f * l3 - 3.3077115913f * m3 + 0.2309699292f * s3;
    o.g = -1.2684380046f * l3 + 2.6097574011f * m3 - 0.3413193965f * s3;
    o.b = -0.0041960863f * l3 - 0.7034186147f * m3 + 1.7076147010f * s3;
    return o;
}

// Colour windows in OKLab hue. Centres = hue of the pure primaries / secondaries.
// Range 1: full effect within +-6 deg, fades to 0 at +-20 deg (smootherstep).
// The fade never gets shorter than 10 deg, and gets longer for strong
// settings (at most ~0.25 stop of change per degree): no edge on a gradient.
DP_CONST float DP_HC[6] = {29.2f, 109.8f, 142.5f, 194.8f, 264.1f, 328.4f};
DP_FN float dp_hueW(float boostUI, float hueUI, float rangeUI, int k, float th)
{
    const float boost = 1.0f + 3.0f * DP_MIN(DP_MAX(boostUI, 0.0f), 100.0f) / 100.0f;
    const float st = DP_MIN(1.4f * boost * DP_FABS(hueUI) / 100.0f, 3.0f);
    const float r = DP_MIN(DP_MAX(rangeUI, 0.1f), 4.0f), core = 6.0f * r;
    const float hw = core + DP_MAX(DP_MAX(14.0f * r, 10.0f), 7.5f * st);
    const float ad = DP_FABS(dp_wrap180(th - DP_HC[k]));
    if (ad <= core) return 1.0f;
    if (ad >= hw) return 0.0f;
    const float t = (ad - core) / (hw - core);
    return 1.0f - t * t * t * (t * (6.0f * t - 15.0f) + 10.0f);
}

// Zones: a partition of unity on brightness (stops from middle grey, moved by
// Zones Pivot). Boundaries at -/+1.375 stop, transition 0.75..4.5 stops.
DP_FN void dp_zones(float zpiv, float zsoft, float st, DP_REF zs, DP_REF zm, DP_REF zh)
{
    const float x = st - DP_MIN(DP_MAX(zpiv, -3.0f), 3.0f);
    const float w = 0.75f + 3.75f * DP_MIN(DP_MAX(zsoft, 0.0f), 1.0f), h = 0.5f * w;
    zs = 1.0f - dp_ss5(-1.375f - h, -1.375f + h, x);
    zh = dp_ss5(1.375f - h, 1.375f + h, x);
    zm = DP_MAX(0.0f, 1.0f - zs - zh);
}

// amount (%, already weighted) -> stops, with the film protections (deep
// blacks, near-white highlights, skin). ev: stops from middle grey.
DP_FN float dp_shape(float boostUI, float amt, float ev, float skin)
{
    const float boost = 1.0f + 3.0f * DP_MIN(DP_MAX(boostUI, 0.0f), 100.0f) / 100.0f;
    float stops = -1.4f * boost * amt / 100.0f;   // 100 % = 1.4 stops on a fully saturated colour
    const float lim = 3.0f;
    stops = lim * DP_TANH(stops / lim);
    const float a = DP_FABS(stops);
    const float pb = dp_sstep(ev, -8.5f, -8.5f + DP_MAX(4.0f, 2.6f * a));
    const float ph = 1.0f - 0.5f * dp_sstep(ev, 2.0f, 2.0f + DP_MAX(2.0f, 1.3f * a));
    return stops * pb * ph * (1.0f - 0.55f * skin);
}

// ---- selection -> density change in stops -------------------------------------
// q: DaVinci Intermediate key colour (clamped 0..1, measured on the softened
// copy of the picture). Returns the change in stops; *showW the Show Mask
// weight (selection of the focused slider x saturation weight).
//   amount = sum_zones z_j a_j + sum_hues h_k b_k (in %), weighted by the
//   saturation weight (neutrals never move); zones on DI luma in stops.
struct DpSel { float stops; float showW; };
#ifdef __METAL_VERSION__
DP_FN DpSel dp_select(constant DensArgs& P, float q0, float q1, float q2)
#else
DP_FN DpSel dp_select(const DensArgs& P, float q0, float q1, float q2)
#endif
{
    DpSel out; out.stops = 0.0f; out.showW = 0.0f;
    const float l0 = DP_MAX(dp_di2lin(q0), 0.0f), l1 = DP_MAX(dp_di2lin(q1), 0.0f), l2 = DP_MAX(dp_di2lin(q2), 0.0f);
    const float mx = DP_MAX(l0, DP_MAX(l1, l2)), mn = DP_MIN(l0, DP_MIN(l1, l2));
    const float sat = mx > 1e-6f ? (mx - mn) / mx : 0.0f;
    const float gam = 0.6f + 1.8f * DP_MIN(DP_MAX(P.focus, 0.0f), 100.0f) / 100.0f;
    const float Y = 0.2126f * l0 + 0.7152f * l1 + 0.0722f * l2;
    const float sw = sat > 0.0f ? DP_EXP2(gam * DP_LOG2(DP_MIN(sat, 1.0f))) * dp_sstep(sat, 0.0f, 0.15f) : 0.0f;
    if (sw <= 1e-6f && !P.show) return out;          // neutral: nothing to do
    const float Ld = 0.2126f * q0 + 0.7152f * q1 + 0.0722f * q2, st = (Ld - DP_PIV) / 0.07329248f;
    float zs = 0.0f, zm = 0.0f, zh = 0.0f;
    dp_zones(P.zpiv, P.zsoft, st, zs, zm, zh);
    // Show Zones: the TONAL zones themselves (where the zone sliders reach),
    // not weighted by saturation, so the zones can be placed on any picture.
    //   6..8 one zone: its weight (1 inside, 0 outside, soft between);
    //   9 the zone map: the value is the tone in stops (continuous, so the
    //   grid interpolates it exactly), turned into the three zones by
    //   dp_apply_value.
    if (P.show && P.maskFocus >= 6 && P.maskFocus <= 9) {
        const int f = P.maskFocus;
        out.showW = f == 6 ? zs : (f == 7 ? zm : (f == 8 ? zh : st));
        return out;
    }
    float amt = P.lam * (zs * P.zone[0] + zm * P.zone[1] + zh * P.zone[2]);
    float sel = DP_MAX(P.zone[0] != 0.0f ? zs : 0.0f, DP_MAX(P.zone[1] != 0.0f ? zm : 0.0f, P.zone[2] != 0.0f ? zh : 0.0f));
    const DpLab lab = dp_oklab(l0, l1, l2);
    const float C = DP_SQRT(lab.A * lab.A + lab.B * lab.B), h = C > 1e-6f ? dp_atan2deg(lab.B, lab.A) : 0.0f;
    // colour windows: where two active windows overlap they share the pixel
    float hw[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float hsum = 0.0f;
    if (C > 1e-6f)
        for (int k = 0; k < 6; ++k) { hw[k] = dp_hueW(P.boost, P.hue[k], P.range[k], k, h); if (P.hue[k] != 0.0f) hsum += hw[k]; }
    const float hn = 1.0f / DP_MAX(1.0f, hsum);
    for (int k = 0; k < 6; ++k)
        if (P.hue[k] != 0.0f) { amt += P.hue[k] * hw[k] * hn; sel = DP_MAX(sel, hw[k] * hn); }
    if (P.show) {
        // the selection of the slider last touched (a colour: its own window,
        // shared with the active neighbours; a zone; the three zones) or of
        // every active slider
        const int f = P.maskFocus;
        float s = sel;
        if (f >= 0 && f <= 5) { const float s2 = hsum + (P.hue[f] != 0.0f ? 0.0f : hw[f]); s = hw[f] / DP_MAX(1.0f, s2); }
        else if (f == 10) {   // every active colour (the zones left out)
            s = 0.0f;
            for (int k = 0; k < 6; ++k) if (P.hue[k] != 0.0f) s = DP_MAX(s, hw[k] * hn);
        }
        out.showW = s * sw;
        return out;
    }
    if (amt == 0.0f || sw <= 0.0f) return out;
    const float dh = DP_FABS(dp_wrap180(h - 50.0f));
    const float skin = (1.0f - dp_sstep(dh, 8.0f, 22.0f)) * dp_sstep(C, 0.02f, 0.05f) * (1.0f - dp_sstep(C, 0.12f, 0.18f));
    out.stops = dp_shape(P.boost, amt * sw, DP_LOG2(DP_MAX(Y, 1e-10f) / 0.18f), skin);
    return out;
}

// Film density: like adding / removing dye, in OKLab. Lightness follows the
// exposure change, chroma only part of it (a denser colour keeps more colour
// than it loses light), hue unchanged; the result stays inside the gamut with
// a continuous chroma limit (bisection). Applied as a ratio to the real
// (unclamped) pixel, so values outside 0..1 keep their relationship.
DP_FN DpRGB dp_filmDensity(DpRGB c, float s)
{
    const float q0 = dp_clamp01(c.r), q1 = dp_clamp01(c.g), q2 = dp_clamp01(c.b);
    const float l0 = DP_MAX(dp_di2lin(q0), 0.0f), l1 = DP_MAX(dp_di2lin(q1), 0.0f), l2 = DP_MAX(dp_di2lin(q2), 0.0f);
    const DpLab lab = dp_oklab(l0, l1, l2);
    if (lab.L <= 1e-6f || s == 0.0f) return c;
    const float kL = DP_EXP2(s / 3.0f);
    const float cf = s < 0.0f ? 0.55f : 0.8f;
    const float kC = DP_EXP2(cf * s / 3.0f);
    const float L2 = lab.L * kL;
    float sc = kC;
    DpRGB o = dp_oklabInv(L2, lab.A * sc, lab.B * sc);
    if (DP_MIN(o.r, DP_MIN(o.g, o.b)) < 0.0f) {      // largest chroma scale that keeps every channel >= 0
        float lo = 0.0f, hi = sc;
        for (int it = 0; it < 12; ++it) {
            const float m = 0.5f * (lo + hi);
            const DpRGB t = dp_oklabInv(L2, lab.A * m, lab.B * m);
            if (DP_MIN(t.r, DP_MIN(t.g, t.b)) >= 0.0f) lo = m; else hi = m;
        }
        sc = lo;
        o = dp_oklabInv(L2, lab.A * sc, lab.B * sc);
    }
    const float o0 = DP_MAX(o.r, 0.0f), o1 = DP_MAX(o.g, 0.0f), o2 = DP_MAX(o.b, 0.0f);
    DpRGB r;
    r.r = q0 == c.r ? dp_lin2di(o0) : dp_lin2di(dp_di2lin(c.r) * (o0 + 1e-5f) / (l0 + 1e-5f));
    r.g = q1 == c.g ? dp_lin2di(o1) : dp_lin2di(dp_di2lin(c.g) * (o1 + 1e-5f) / (l1 + 1e-5f));
    r.b = q2 == c.b ? dp_lin2di(o2) : dp_lin2di(dp_di2lin(c.b) * (o2 + 1e-5f) / (l2 + 1e-5f));
    return r;
}

// ---- conversions between the input encoding and RELIEF's working space -------
// (tx_decode / tx_encode: the DCTL's own log curves, from NodeTextureMath.h)
#ifdef __METAL_VERSION__
DP_FN DpRGB dp_toWork(constant DensArgs& A, float r, float g, float b)
#else
DP_FN DpRGB dp_toWork(const DensArgs& A, float r, float g, float b)
#endif
{
    DpRGB o;
    if (A.direct) { o.r = r; o.g = g; o.b = b; return o; }
    const float a0 = tx_decode(A.oetf, r), a1 = tx_decode(A.oetf, g), a2 = tx_decode(A.oetf, b);
    o.r = dp_lin2di(A.mIn[0] * a0 + A.mIn[1] * a1 + A.mIn[2] * a2);
    o.g = dp_lin2di(A.mIn[3] * a0 + A.mIn[4] * a1 + A.mIn[5] * a2);
    o.b = dp_lin2di(A.mIn[6] * a0 + A.mIn[7] * a1 + A.mIn[8] * a2);
    return o;
}
#ifdef __METAL_VERSION__
DP_FN DpRGB dp_fromWork(constant DensArgs& A, DpRGB c)
#else
DP_FN DpRGB dp_fromWork(const DensArgs& A, DpRGB c)
#endif
{
    if (A.direct) return c;
    const float a0 = dp_di2lin(c.r), a1 = dp_di2lin(c.g), a2 = dp_di2lin(c.b);
    DpRGB o;
    o.r = tx_encode(A.oetf, A.mOut[0] * a0 + A.mOut[1] * a1 + A.mOut[2] * a2);
    o.g = tx_encode(A.oetf, A.mOut[3] * a0 + A.mOut[4] * a1 + A.mOut[5] * a2);
    o.b = tx_encode(A.oetf, A.mOut[6] * a0 + A.mOut[7] * a1 + A.mOut[8] * a2);
    return o;
}

// The selection value of a key colour: the change in stops, or with Show Mask
// the mask weight (what RELIEF's grid holds).
#ifdef __METAL_VERSION__
DP_FN float dp_selValue(constant DensArgs& A, float k0, float k1, float k2)
#else
DP_FN float dp_selValue(const DensArgs& A, float k0, float k1, float k2)
#endif
{
    const DpSel s = dp_select(A, dp_clamp01(k0), dp_clamp01(k1), dp_clamp01(k2));
    return A.show ? s.showW : s.stops;
}
// RELIEF's grid: below 0.02 stop (or mask weight) between the 4 grid values,
// interpolating is the exact result; otherwise the pixel is measured itself.
DP_FN bool dp_gridAgrees(float g00, float g01, float g10, float g11)
{
    const float lo = DP_MIN(DP_MIN(g00, g01), DP_MIN(g10, g11)), hi = DP_MAX(DP_MAX(g00, g01), DP_MAX(g10, g11));
    return hi - lo <= 0.02f;
}
DP_FN float dp_gridLerp(float g00, float g01, float g10, float g11, float wx, float wy)
{
    return (g00 * (1.0f - wx) + g01 * wx) * (1.0f - wy) + (g10 * (1.0f - wx) + g11 * wx) * wy;
}

// One pixel: p the input pixel (its encoding), v its selection value (see
// dp_selValue). Returns the output pixel; an untouched pixel bit for bit.
#ifdef __METAL_VERSION__
DP_FN DpRGB dp_apply_value(constant DensArgs& A, DpRGB p, float v)
#else
DP_FN DpRGB dp_apply_value(const DensArgs& A, DpRGB p, float v)
#endif
{
    if (!A.show && v == 0.0f) return p;
    const DpRGB c = dp_toWork(A, p.r, p.g, p.b);
    DpRGB n;
    if (A.show && A.maskFocus == 9) {
        // Zone map: the picture in grey, tinted by zone - Shadows blue,
        // Midtones green, Highlights orange - with soft transitions exactly
        // where the zones overlap. Its own tone is kept, so the picture stays
        // readable.
        float zs = 0.0f, zm = 0.0f, zh = 0.0f;
        dp_zones(A.zpiv, A.zsoft, v, zs, zm, zh);
        const float t = DP_MAX(zs + zm + zh, 1e-6f);
        // tone flattened around grey (half the contrast), so the blue of the
        // shadows stays readable in the dark parts of the picture
        const float Ld = DP_PIV + 0.5f * (0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b - DP_PIV);
        const float k = 0.12f / t;
        n.r = Ld + k * (-0.55f * zs - 0.30f * zm + 0.60f * zh);
        n.g = Ld + k * (-0.05f * zs + 0.45f * zm + 0.05f * zh);
        n.b = Ld + k * ( 0.75f * zs - 0.30f * zm - 0.85f * zh);
    } else if (A.show) {   // pixels outside the selection turn grey
        n.r = DP_PIV + v * (c.r - DP_PIV);
        n.g = DP_PIV + v * (c.g - DP_PIV);
        n.b = DP_PIV + v * (c.b - DP_PIV);
    } else {
        n = dp_filmDensity(c, v);
    }
    if (A.direct) return n;
    // only the change is re-encoded: in + (enc(new) - enc(old))
    const DpRGB e1 = dp_fromWork(A, n), e0 = dp_fromWork(A, c);
    DpRGB o;
    o.r = p.r + (e1.r - e0.r);
    o.g = p.g + (e1.g - e0.g);
    o.b = p.b + (e1.b - e0.b);
    return o;
}

// One pixel measured on its own key (no grid): the reference behaviour.
#ifdef __METAL_VERSION__
DP_FN DpRGB dp_pixel(constant DensArgs& A, DpRGB p, float k0, float k1, float k2)
#else
DP_FN DpRGB dp_pixel(const DensArgs& A, DpRGB p, float k0, float k1, float k2)
#endif
{
    return dp_apply_value(A, p, dp_selValue(A, k0, k1, k2));
}

#line 1 "NodeDensity.metal"
// =============================================================================
//  NODE_DRT — Density Pro, Metal kernels
// -----------------------------------------------------------------------------
//  Baked after NodeTextureMath.h and NodeDensityMath.h into
//  gen/density_metal_src.h. Same passes and same arithmetic as densityCPU() in
//  NodeDensity.cpp, compiled with fast-math off. Buffers are OFX rows.
// =============================================================================

inline int dp_ci(int v, int a, int b) { return v < a ? a : (v > b ? b : v); }

// 1. the selection key: the picture in DaVinci Intermediate, clamped to 0..1
kernel void dp_key(constant DensArgs& A [[buffer(0)]], const device float* src [[buffer(1)]],
                   device float* K [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W || y >= A.H) return;
    const device float* p = src + y * A.srcRow + x * 4;
    const DpRGB c = dp_toWork(A, p[0], p[1], p[2]);
    device float* k = K + (y * A.W + x) * 3;
    k[0] = dp_clamp01(c.r); k[1] = dp_clamp01(c.g); k[2] = dp_clamp01(c.b);
}

// 2. soft mask: three horizontal + three vertical box passes (~ gaussian).
//  - horizontal: a threadgroup covers a run of one row and reads it once into
//    threadgroup memory; each pixel then sums its 2r + 1 neighbours from there
//    (reading a row from device memory one thread per row was 5x slower);
//  - vertical: running sums over runs of DP_SEG rows of one float column -
//    neighbouring threads read neighbouring floats, a few operations per pixel
//    whatever the radius.
// densityCPU() runs the very same additions in the same order.
constant int DP_SEG = 64;
kernel void dp_boxh(constant DensArgs& A [[buffer(0)]], const device float* in [[buffer(1)]],
                    device float* out [[buffer(2)]], threadgroup float* tb [[threadgroup(0)]],
                    uint2 tid [[thread_position_in_threadgroup]], uint2 tgid [[threadgroup_position_in_grid]],
                    uint2 tgs [[threads_per_threadgroup]])
{
    const int TW = (int)tgs.x, W = A.W, r = A.blurR;
    const int x0 = (int)tgid.x * TW, y = (int)tgid.y;
    const int span = TW + 2 * r;
    const device float* s = in + y * W * 3;
    for (int k = (int)tid.x; k < span; k += TW) {
        const int xs = dp_ci(x0 - r + k, 0, W - 1);
        tb[k * 3 + 0] = s[xs * 3 + 0];
        tb[k * 3 + 1] = s[xs * 3 + 1];
        tb[k * 3 + 2] = s[xs * 3 + 2];
    }
    metal::threadgroup_barrier(metal::mem_flags::mem_threadgroup);
    const int x = x0 + (int)tid.x;
    if (x >= W || y >= A.H) return;
    const float inv = 1.0f / (float)(2 * r + 1);
    for (int c = 0; c < 3; ++c) {
        float acc = 0.0f;
        for (int i = 0; i <= 2 * r; ++i) acc += tb[((int)tid.x + i) * 3 + c];
        out[(y * W + x) * 3 + c] = acc * inv;
    }
}
kernel void dp_boxv(constant DensArgs& A [[buffer(0)]], const device float* in [[buffer(1)]],
                    device float* out [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int i = (int)gid.x, y0 = (int)gid.y * DP_SEG;   // i: one float column (pixel x, channel c)
    const int W = A.W, H = A.H;
    if (i >= W * 3 || y0 >= H) return;
    const int y1 = min(y0 + DP_SEG, H), r = A.blurR;
    const float inv = 1.0f / (float)(2 * r + 1);
    float acc = 0.0f;
    for (int y = y0 - r; y <= y0 + r; ++y) acc += in[dp_ci(y, 0, H - 1) * W * 3 + i];
    for (int y = y0; y < y1; ++y) {
        out[y * W * 3 + i] = acc * inv;
        acc += in[min(y + r + 1, H - 1) * W * 3 + i] - in[max(y - r, 0) * W * 3 + i];
    }
}

// 3. the selection (stops, or the Show Mask weight) on every 2nd pixel of every
// 2nd row - RELIEF's grid: the expensive maths runs on a quarter of the pixels.
kernel void dp_grid(constant DensArgs& A [[buffer(0)]], const device float* K [[buffer(1)]],
                    device float* G [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int Wl = (A.W - 1) / 2 + 2, Hl = (A.H - 1) / 2 + 2;
    const int lx = (int)gid.x, ly = (int)gid.y;
    if (lx >= Wl || ly >= Hl) return;
    const int x = min(lx * 2, A.W - 1), y = min(ly * 2, A.H - 1);
    const device float* k = K + (y * A.W + x) * 3;
    G[ly * Wl + lx] = dp_selValue(A, k[0], k[1], k[2]);
}

// 4. per pixel: the selection interpolated from the grid where its 4 grid
// values agree (within 0.02 stop), measured exactly where they do not (mask
// edges, fine coloured detail); then film density on the real pixel.
kernel void dp_apply(constant DensArgs& A [[buffer(0)]], const device float* src [[buffer(1)]],
                     device float* dst [[buffer(2)]], const device float* K [[buffer(3)]],
                     const device float* G [[buffer(4)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W || y >= A.H) return;
    const int Wl = (A.W - 1) / 2 + 2;
    const device float* p = src + y * A.srcRow + x * 4;
    device float* d = dst + y * A.dstRow + x * 4;
    const int lx = x / 2, ly = y / 2;
    const float wx = (float)(x - lx * 2) / 2.0f, wy = (float)(y - ly * 2) / 2.0f;
    const float g00 = G[ly * Wl + lx], g01 = G[ly * Wl + lx + 1], g10 = G[(ly + 1) * Wl + lx], g11 = G[(ly + 1) * Wl + lx + 1];
    float v;
    if (dp_gridAgrees(g00, g01, g10, g11)) v = dp_gridLerp(g00, g01, g10, g11, wx, wy);
    else { const device float* k = K + (y * A.W + x) * 3; v = dp_selValue(A, k[0], k[1], k[2]); }
    DpRGB c; c.r = p[0]; c.g = p[1]; c.b = p[2];
    const DpRGB o = dp_apply_value(A, c, v);
    d[0] = o.r; d[1] = o.g; d[2] = o.b; d[3] = p[3];
}
