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
#pragma once

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
    int maskFocus;       // -1 every active slider, 0..5 a colour, 6..8 a zone, 9 the zones
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
        else if (f == 6) s = zs;
        else if (f == 7) s = zm;
        else if (f == 8) s = zh;
        else if (f == 9) s = DP_MAX(P.zone[0] != 0.0f ? zs : 0.0f, DP_MAX(P.zone[1] != 0.0f ? zm : 0.0f, P.zone[2] != 0.0f ? zh : 0.0f));
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
    if (A.show) {   // pixels outside the selection turn grey
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
