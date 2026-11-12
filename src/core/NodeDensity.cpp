// =============================================================================
//  NODE_DRT — Density Pro: arguments and CPU path
// -----------------------------------------------------------------------------
//  Passes (the GPU runs the same ones, see NodeDensity.metal):
//    1. key: the picture in DaVinci Intermediate, clamped to 0..1
//    2. soft mask: 3 x (horizontal + vertical) box passes over the key, a close
//       gaussian of the Mask Softness radius (RELIEF's softened selection)
//    3. the selection field (amount x saturation weight, saturation weight,
//       skin protection) on the softened key, on a half-resolution grid
//    4. the field blurred (3 x box passes, Mask Softness), at half resolution
//    5. per pixel: smooth amount x the pixel's own saturation weight, film
//       density on the real pixel, only the change re-encoded
// =============================================================================
// BUILD NOTE: this file is compiled inside NodeTexture.cpp's translation unit
// (see the #include at the end of NodeTexture.cpp), so the build needs no new
// object file. Its helpers carry a dp prefix for that reason.
#include "NodeDensity.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace nodeone {
namespace {

// Input gamut -> XYZ: the DCTL's matrix_*_to_xyz, in in_gamut order.
const double kToXYZ[16][9] = {
    {1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0},   // XYZ
    {0.93863094875, -0.00574192055, 0.017566898852, 0.338093594922, 0.727213902811, -0.065307497733, 0.000723121511, 0.000818441849, 1.0875161874},   // ACES 2065-1
    {0.652418717672, 0.127179925538, 0.170857283842, 0.268064059194, 0.672464478993, 0.059471461813, -0.00546992851, 0.005182799977, 1.08934487929},   // ACEScg
    {0.486571133137, 0.265667706728, 0.198217317462, 0.228974640369, 0.691738605499, 0.079286918044, 0.0, 0.045113388449, 1.043944478035},   // P3D65
    {0.636958122253, 0.144616916776, 0.168880969286, 0.262700229883, 0.677998125553, 0.059301715344, 0.0, 0.028072696179, 1.060985088348},   // Rec.2020
    {0.412390917540, 0.357584357262, 0.180480793118, 0.212639078498, 0.715168714523, 0.072192311287, 0.019330825657, 0.119194783270, 0.950532138348},   // Rec.709
    {0.638007619284, 0.214703856337, 0.097744451431, 0.291953779, 0.823841041511, -0.11579482051, 0.002798279032, -0.067034235689, 1.15329370742},   // AWG3
    {0.704858320407, 0.12976029517, 0.115837311474, 0.254524176404, 0.781477732712, -0.036001909116, 0.0, 0.0, 1.08905775076},   // AWG4
    {0.735275208950, 0.068609409034, 0.146571278572, 0.286694079638, 0.842979073524, -0.129673242569, -0.079680845141, -0.347343206406, 1.516081929207},   // RWG
    {0.706482713192, 0.128801049791, 0.115172164069, 0.270979670813, 0.786606411221, -0.057586082034, -0.009677845386, 0.004600037493, 1.09413555865},   // S-Gamut3
    {0.599083920758, 0.248925516115, 0.102446490178, 0.215075820116, 0.885068501744, -0.100144321859, -0.032065849545, -0.027658390679, 1.14878199098},   // S-Gamut3.Cine
    {0.679644469878, 0.15221141244, 0.118600044733, 0.26068555009, 0.77489446333, -0.03558001342, -0.009310198218, -0.004612467044, 1.10298041602},   // V-Gamut
    {0.606538414955, 0.220412746072, 0.123504832387, 0.267992943525, 0.832748472691, -0.100741356611, -0.029442556202, -0.086612440646, 1.205112814903},   // BMD WG
    {0.705396831036, 0.164041340351, 0.081017754972, 0.280130714178, 0.820206701756, -0.100337378681, -0.103781513870, -0.072907261550, 1.265746593475},   // E-Gamut
    {0.736477700184, 0.130739651087, 0.083238575781, 0.275069984406, 0.828017790216, -0.103087774621, -0.124225154248, -0.087159767391, 1.3004426724},   // E-Gamut2
    {0.700622320175, 0.148774802685, 0.101058728993, 0.274118483067, 0.873631775379, -0.147750422359, -0.098962903023, -0.137895315886, 1.325916051865},   // DaVinci WG
};
const int kDWG = 15;

void mul3(const double* a, const double* b, double* o)
{
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) o[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c];
}
void inv3(const double* m, double* o)
{
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
    const double det = a * A + b * B + c * C;
    const double k = det != 0.0 ? 1.0 / det : 0.0;
    o[0] = A * k; o[1] = -(b * i - c * h) * k; o[2] = (b * f - c * e) * k;
    o[3] = B * k; o[4] = (a * i - c * g) * k;  o[5] = -(a * f - c * d) * k;
    o[6] = C * k; o[7] = -(a * h - b * g) * k; o[8] = (a * e - b * d) * k;
}

template <class F>
void dpParallelRows(int n, F f)
{
    if (n <= 0) return;
    unsigned nt = std::max(1u, std::thread::hardware_concurrency());
    nt = std::min<unsigned>(nt, (unsigned)n);
    if (nt == 1) { for (int y = 0; y < n; ++y) f(y); return; }
    std::vector<std::thread> pool;
    pool.reserve(nt);
    for (unsigned i = 0; i < nt; ++i) {
        const int a = (int)((long long)n * i / nt), b = (int)((long long)n * (i + 1) / nt);
        pool.emplace_back([=, &f] { for (int y = a; y < b; ++y) f(y); });
    }
    for (auto& t : pool) t.join();
}

inline int dpClampi(int v, int a, int b) { return v < a ? a : (v > b ? b : v); }

// TONE SAFETY (RELIEF's dpSafeScale). The zone sliders depend on brightness, so
// strong settings could reverse or stretch the tonal order of a gradient
// (banding, solarised edges). Every brightness is scanned for every
// combination of the active colour sliders, and one global scale (<= 1) of the
// zone sliders keeps the result a smooth increasing function of the input:
// slope between 0.35 and 2.5. A single constant scale keeps the result exactly
// smooth (a per-pixel limiter would itself create steps).
float safeScale(const DensitySettings& P)
{
    if (P.zone[0] == 0.0f && P.zone[1] == 0.0f && P.zone[2] == 0.0f) return 1.0f;
    std::vector<float> hs = {0.0f};
    float pos = 0.0f, neg = 0.0f;
    for (int k = 0; k < 6; ++k)
        if (P.hue[k] != 0.0f) { hs.push_back(P.hue[k]); if (P.hue[k] > 0.0f) pos += P.hue[k]; else neg += P.hue[k]; }
    hs.push_back(pos);
    hs.push_back(neg);
    float lam = 1.0f;
    for (int it = 0; it < 40; ++it) {
        float smin = 1e9f, smax = -1e9f;
        for (float ha : hs)
            for (float sk : {0.0f, 1.0f}) {
                float prev = 0.0f;
                bool first = true;
                const float dst = 0.05f;
                for (float ev = -12.0f; ev <= 6.0f; ev += dst) {
                    const float Y = 0.18f * std::exp2(ev), Ld = dp_lin2di(Y), stz = (Ld - DP_PIV) / 0.07329248f;
                    float zs, zm, zh;
                    dp_zones(P.zpiv, P.zsoft, stz, zs, zm, zh);
                    const float amt = lam * (zs * P.zone[0] + zm * P.zone[1] + zh * P.zone[2]) + ha;
                    const float out = ev + dp_shape(P.boost, amt, ev, sk);
                    if (!first) { const float sl = (out - prev) / dst; smin = std::min(smin, sl); smax = std::max(smax, sl); }
                    prev = out;
                    first = false;
                }
            }
        if (smin >= 0.35f && smax <= 2.5f) break;
        lam *= 0.92f;
    }
    return lam;
}

// The scan costs a few milliseconds: done once per setting, not per frame.
float safeScaleCached(const DensitySettings& P)
{
    static std::mutex m;
    static float key[12] = {NAN};
    static float val = 1.0f;
    const float k[12] = {P.zone[0], P.zone[1], P.zone[2], P.hue[0], P.hue[1], P.hue[2], P.hue[3], P.hue[4], P.hue[5],
                         P.boost, P.zpiv, P.zsoft};
    std::lock_guard<std::mutex> lock(m);
    if (std::memcmp(k, key, sizeof(k)) == 0) return val;
    val = safeScale(P);
    std::memcpy(key, k, sizeof(k));
    return val;
}

} // namespace

void densityPlan(const DensitySettings& s, int W, int H, DensityPlan& plan)
{
    DensArgs& a = plan.a;
    std::memset(&a, 0, sizeof(a));
    a.W = W; a.H = H;
    a.oetf = dpClampi(s.oetf, 0, 9);
    const int g = dpClampi(s.gamut, 0, 15);
    a.direct = (g == kDWG && a.oetf == 1) ? 1 : 0;
    double toDWG[9], mIn[9], mOut[9];
    inv3(kToXYZ[kDWG], toDWG);
    mul3(toDWG, kToXYZ[g], mIn);
    inv3(mIn, mOut);
    for (int i = 0; i < 9; ++i) { a.mIn[i] = (float)mIn[i]; a.mOut[i] = (float)mOut[i]; }
    a.show = s.show ? 1 : 0;
    a.maskFocus = s.maskFocus;
    for (int i = 0; i < 3; ++i) a.zone[i] = s.zone[i];
    for (int i = 0; i < 6; ++i) { a.hue[i] = s.hue[i]; a.range[i] = s.range[i]; }
    a.boost = s.boost; a.focus = s.focus; a.zpiv = s.zpiv; a.zsoft = s.zsoft;
    a.lam = safeScaleCached(s);
    // Mask Softness: RELIEF's gaussian radius, in pixels of a 1080-line frame
    // scaled to this one, as 3 box passes of the matching width.
    const float ms = std::min(std::max(s.maskSoft, 0.0f), 1.0f);
    const float sigma = (0.5f + 6.0f * ms * std::sqrt(ms)) * (float)H / 1080.0f;
    a.blurR = (sigma < 0.3f || W < 2 || H < 2) ? 0
                                               : std::max(1, (int)std::floor(std::sqrt(12.0f * sigma * sigma / 3.0f + 1.0f) / 2.0f));
    // v2: the selection FIELD is blurred too, wider: 1.5 px at 0, 8.5 px at
    // 0.5 (default), 15.5 px at 1, in pixels of a 1080-line frame - on the
    // half-resolution grid, hence the / 2.
    const float sigF = 0.5f * (1.5f + 14.0f * ms) * (float)H / 1080.0f;
    a.fieldR = (sigF < 0.3f || W < 2 || H < 2) ? 0
                                               : std::max(1, (int)std::floor(std::sqrt(12.0f * sigF * sigF / 3.0f + 1.0f) / 2.0f));
}

void densityCPU(const DensityPlan& plan, const float* src, ptrdiff_t srcRow, float* dst, ptrdiff_t dstRow)
{
    const DensArgs& A = plan.a;
    const int W = A.W, H = A.H;
    std::vector<float> K((size_t)W * H * 3), T;
    dpParallelRows(H, [&](int y) {
        for (int x = 0; x < W; ++x) {
            const float* p = src + (ptrdiff_t)y * srcRow + (ptrdiff_t)x * 4;
            const DpRGB c = dp_toWork(A, p[0], p[1], p[2]);
            float* k = &K[((size_t)y * W + x) * 3];
            k[0] = dp_clamp01(c.r); k[1] = dp_clamp01(c.g); k[2] = dp_clamp01(c.b);
        }
    });
    // 3 x (horizontal + vertical) box passes of radius r over a BW x BH x 3
    // buffer, the same additions in the same order as the GPU: horizontal =
    // direct sum of the 2r + 1 neighbours, vertical = running sums over runs
    // of 64 rows.
    auto box3 = [&](std::vector<float>& B, int BW, int BH, int r) {
        if (r <= 0) return;
        T.resize(B.size());
        const int SEG = 64;
        const float inv = 1.0f / (float)(2 * r + 1);
        for (int pass = 0; pass < 3; ++pass) {
            dpParallelRows(BH, [&](int y) {
                const float* s = &B[(size_t)y * BW * 3];
                float* d = &T[(size_t)y * BW * 3];
                for (int x = 0; x < BW; ++x)
                    for (int c = 0; c < 3; ++c) {
                        float acc = 0.0f;
                        for (int i = 0; i <= 2 * r; ++i) acc += s[dpClampi(x - r + i, 0, BW - 1) * 3 + c];
                        d[x * 3 + c] = acc * inv;
                    }
            });
            dpParallelRows((BH + SEG - 1) / SEG, [&](int b) {
                const int y0 = b * SEG, y1 = std::min(y0 + SEG, BH);
                for (int i = 0; i < BW * 3; ++i) {
                    float acc = 0.0f;
                    for (int y = y0 - r; y <= y0 + r; ++y) acc += T[(size_t)dpClampi(y, 0, BH - 1) * BW * 3 + i];
                    for (int y = y0; y < y1; ++y) {
                        B[(size_t)y * BW * 3 + i] = acc * inv;
                        acc += T[(size_t)std::min(y + r + 1, BH - 1) * BW * 3 + i] - T[(size_t)std::max(y - r, 0) * BW * 3 + i];
                    }
                }
            });
        }
    };
    box3(K, W, H, A.blurR);
    // the selection field on every 2nd pixel of every 2nd row (RELIEF's grid) ...
    const int Wl = (W - 1) / 2 + 2, Hl = (H - 1) / 2 + 2;
    std::vector<float> G((size_t)Wl * Hl * 3);
    dpParallelRows(Hl, [&](int ly) {
        const int y = std::min(ly * 2, H - 1);
        for (int lx = 0; lx < Wl; ++lx) {
            const int x = std::min(lx * 2, W - 1);
            const float* k = &K[((size_t)y * W + x) * 3];
            const DpField f = dp_field(A, k[0], k[1], k[2]);
            float* g = &G[((size_t)ly * Wl + lx) * 3];
            g[0] = f.f0; g[1] = f.f1; g[2] = f.f2;
        }
    });
    // ... blurred (Mask Softness) ...
    box3(G, Wl, Hl, A.fieldR);
    // ... read back per pixel, times the pixel's own saturation weight.
    dpParallelRows(H, [&](int y) {
        const int ly = y / 2;
        const float wy = (float)(y - ly * 2) / 2.0f;
        for (int x = 0; x < W; ++x) {
            const float* p = src + (ptrdiff_t)y * srcRow + (ptrdiff_t)x * 4;
            float* d = dst + (ptrdiff_t)y * dstRow + (ptrdiff_t)x * 4;
            const int lx = x / 2;
            const float wx = (float)(x - lx * 2) / 2.0f;
            const float* g00 = &G[((size_t)ly * Wl + lx) * 3];
            const float* g01 = g00 + 3;
            const float* g10 = g00 + (size_t)Wl * 3;
            const float* g11 = g10 + 3;
            const float f0 = dp_gridLerp(g00[0], g01[0], g10[0], g11[0], wx, wy);
            const float f1 = dp_gridLerp(g00[1], g01[1], g10[1], g11[1], wx, wy);
            const float f2 = dp_gridLerp(g00[2], g01[2], g10[2], g11[2], wx, wy);
            const float* k = &K[((size_t)y * W + x) * 3];
            const float v = dp_finish(A, k[0], k[1], k[2], f0, f1, f2);
            DpRGB c; c.r = p[0]; c.g = p[1]; c.b = p[2];
            const DpRGB o = dp_apply_value(A, c, v);
            d[0] = o.r; d[1] = o.g; d[2] = o.b; d[3] = p[3];
        }
    });
}

} // namespace nodeone
