// =============================================================================
//  NODE_DRT — Texture stage (Grain + Halation): kernel tables and CPU path
// -----------------------------------------------------------------------------
//  Passes (the GPU runs the same ones, see NodeTexture.metal):
//    1. halation source S = halSource(Y) of every pixel (decoded to linear)
//    2. (large frames) S averaged 2 x 2 onto a half-resolution grid
//    3. + 4. the halation kernel, a sum of six separable terms: horizontal
//       pass for the six terms, vertical pass summing them -> B
//    5. grain: hash noise, horizontal pass of the gauge's kernel over a padded
//       band (valid convolution: no tile seam, no edge effect)
//    6. per pixel: vertical grain pass, halation + grain, re-encode the change
// =============================================================================
#include "NodeTexture.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>

namespace nodeone {
namespace {

// ---- measured kernels -------------------------------------------------------
// halation: six separable terms of the measured radial kernel, at 4K UHD
static const int HX_R = 16;
static const float HX_SV[6] = {0.04499572f, -0.01129527f, 0.00638589f, -0.00365030f, 0.00291850f, -0.00201647f};
static const float HX_U[6][33] = {{-0.00069106f, -0.00869063f, -0.01574631f, -0.07226165f, -0.09530053f, -0.08771271f, -0.09482006f, -0.09091598f, -0.11639190f, -0.14176117f, -0.15933983f, -0.18640873f, -0.25409698f, -0.32047523f, -0.30770510f, -0.26921776f, -0.25381511f, -0.26921776f, -0.30770510f, -0.32047523f, -0.25409698f, -0.18640873f, -0.15933983f, -0.14176117f, -0.11639190f, -0.09091598f, -0.09482006f, -0.08771271f, -0.09530053f, -0.07226165f, -0.01574631f, -0.00869063f, -0.00069106f}, {-0.00556601f, -0.00299752f, -0.00830794f, -0.08851234f, 0.00732631f, 0.03515019f, -0.01049389f, 0.03223227f, -0.07588571f, -0.03486531f, -0.03511067f, -0.08092884f, -0.28712798f, -0.29881437f, 0.09977049f, 0.40186775f, 0.51318129f, 0.40186775f, 0.09977049f, -0.29881437f, -0.28712798f, -0.08092884f, -0.03511067f, -0.03486531f, -0.07588571f, 0.03223227f, -0.01049389f, 0.03515019f, 0.00732631f, -0.08851234f, -0.00830794f, -0.00299752f, -0.00556601f}, {-0.00026315f, -0.01804378f, -0.01641448f, -0.14486801f, -0.03224446f, 0.16729382f, 0.24003767f, 0.32021482f, 0.27503747f, 0.20760807f, 0.19200870f, 0.14651233f, -0.02130259f, -0.23488400f, -0.22550021f, -0.07474623f, -0.01371671f, -0.07474623f, -0.22550021f, -0.23488400f, -0.02130259f, 0.14651233f, 0.19200870f, 0.20760807f, 0.27503747f, 0.32021482f, 0.24003767f, 0.16729382f, -0.03224446f, -0.14486801f, -0.01641448f, -0.01804378f, -0.00026315f}, {0.00165634f, 0.01093185f, 0.04735590f, 0.09339239f, 0.26547678f, 0.41568884f, 0.31201552f, 0.08416967f, -0.09492325f, -0.24582540f, -0.21189631f, -0.14767719f, 0.00116404f, 0.05064965f, -0.00028234f, -0.03557905f, -0.04935249f, -0.03557905f, -0.00028234f, 0.05064965f, 0.00116404f, -0.14767719f, -0.21189631f, -0.24582540f, -0.09492325f, 0.08416967f, 0.31201552f, 0.41568884f, 0.26547678f, 0.09339239f, 0.04735590f, 0.01093185f, 0.00165634f}, {-0.00473417f, -0.01609186f, -0.02369543f, 0.08553591f, -0.27004710f, -0.16368626f, 0.17074151f, 0.23057834f, 0.23505608f, 0.06771039f, -0.19689481f, -0.32139195f, -0.17671434f, 0.14163822f, 0.22381675f, -0.01279406f, -0.11278064f, -0.01279406f, 0.22381675f, 0.14163822f, -0.17671434f, -0.32139195f, -0.19689481f, 0.06771039f, 0.23505608f, 0.23057834f, 0.17074151f, -0.16368626f, -0.27004710f, 0.08553591f, -0.02369543f, -0.01609186f, -0.00473417f}, {-0.00290427f, -0.06011274f, -0.04334197f, -0.23226841f, -0.46234333f, 0.03617514f, 0.23161326f, -0.02939956f, -0.18279428f, -0.24656451f, -0.07784830f, 0.21377711f, 0.14516690f, 0.03486485f, 0.01378479f, 0.03716793f, 0.04780332f, 0.03716793f, 0.01378479f, 0.03486485f, 0.14516690f, 0.21377711f, -0.07784830f, -0.24656451f, -0.18279428f, -0.02939956f, 0.23161326f, 0.03617514f, -0.46234333f, -0.23226841f, -0.04334197f, -0.06011274f, -0.00290427f}};
// grain: separable 1-D factors of the measured grain kernels at UHD (unit L2)
static const float GX_U65[5] = {-0.0045802f, 0.1398532f, 0.9802245f, 0.1398532f, -0.0045802f};
static const float GX_U35[7] = {-0.0026214f, 0.0226864f, 0.4085475f, 0.8155580f, 0.4085475f, 0.0226864f, -0.0026214f};
// grain amplitude at HD (1080 lines) relative to UHD, measured
static const float GX_AHD[2] = {0.76f, 1.41f};

const float kGamutY[16][3] = {
    {0.0f, 1.0f, 0.0f},                                   // XYZ
    {0.338093594922f, 0.727213902811f, -0.065307497733f},  // ACES 2065-1
    {0.268064059194f, 0.672464478993f, 0.059471461813f},   // ACEScg
    {0.228974640369f, 0.691738605499f, 0.079286918044f},   // P3D65
    {0.262700229883f, 0.677998125553f, 0.059301715344f},   // Rec.2020
    {0.212639078498f, 0.715168714523f, 0.072192311287f},   // Rec.709
    {0.291953779f, 0.823841041511f, -0.11579482051f},      // AWG3
    {0.254524176404f, 0.781477732712f, -0.036001909116f},  // AWG4
    {0.286694079638f, 0.842979073524f, -0.129673242569f},  // RWG
    {0.270979670813f, 0.786606411221f, -0.057586082034f},  // S-Gamut3
    {0.215075820116f, 0.885068501744f, -0.100144321859f},  // S-Gamut3.Cine
    {0.26068555009f, 0.77489446333f, -0.03558001342f},     // V-Gamut
    {0.267992943525f, 0.832748472691f, -0.100741356611f},  // BMD WG
    {0.280130714178f, 0.820206701756f, -0.100337378681f},  // E-Gamut
    {0.275069984406f, 0.828017790216f, -0.103087774621f},  // E-Gamut2
    {0.274118483067f, 0.873631775379f, -0.147750422359f},  // DaVinci WG
};

template <class F>
void parallelRows(int n, F f)
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

inline int clampi(int v, int a, int b) { return v < a ? a : (v > b ? b : v); }

} // namespace

void texturePlan(const TextureSettings& s, int W, int H, TexturePlan& plan)
{
    TexArgs& a = plan.a;
    std::memset(&a, 0, sizeof(a));
    a.W = W; a.H = H;
    a.oetf = clampi(s.oetf, 0, 9);
    a.gamut = clampi(s.gamut, 0, 15);
    a.Yr = kGamutY[a.gamut][0]; a.Yg = kGamutY[a.gamut][1]; a.Yb = kGamutY[a.gamut][2];
    a.halOn = (s.halOn && s.halStrength > 0.0f) ? 1 : 0;
    a.grOn = (s.grainOn && s.amount > 0.0f) ? 1 : 0;
    a.seed = s.seed;

    // ---- halation kernel (scaled to the frame width, half grid when large)
    plan.halK.clear();
    a.W2 = W; a.H2 = H; a.halfRes = 0; a.halR = 0;
    if (a.halOn) {
        float scale = std::max(W / 3840.0f, 0.1f) * std::min(std::max(s.halSize, 0.1f), 8.0f);
        if (scale >= 0.75f) { a.halfRes = 1; a.W2 = (W + 1) / 2; a.H2 = (H + 1) / 2; scale *= 0.5f; }
        const int R = std::max(1, (int)std::ceil(HX_R * scale));
        a.halR = R;
        plan.halK.assign((size_t)6 * (2 * R + 1), 0.0f);
        for (int r = 0; r < 6; ++r) {
            for (int i = -R; i <= R; ++i) {
                const float u = i / scale + HX_R;
                const int k = (int)std::floor(u);
                const float f = u - k;
                float v = 0.0f;
                if (k >= 0 && k <= 2 * HX_R) v += HX_U[r][k] * (1.0f - f);
                if (k + 1 >= 0 && k + 1 <= 2 * HX_R) v += HX_U[r][k + 1] * f;
                plan.halK[(size_t)r * (2 * R + 1) + i + R] = v;
            }
            a.halNorm[r] = HX_SV[r] / (scale * scale);   // the factors are unit-sum at 4K
        }
        // total weight exactly 1 after resampling: a flat area blurs to itself,
        // so it gets no halo of its own (the halo only leaves brighter areas).
        double tot = 0.0;
        for (int r = 0; r < 6; ++r) {
            double sr = 0.0;
            for (int i = 0; i < 2 * R + 1; ++i) sr += plan.halK[(size_t)r * (2 * R + 1) + i];
            tot += a.halNorm[r] * sr * sr;
        }
        if (tot > 1e-6)
            for (int r = 0; r < 6; ++r) a.halNorm[r] = (float)(a.halNorm[r] / tot);
        // SOFTNESS: a normalised gaussian diffusion of the halo on its own
        // grid. The total light of the halo is kept (unit sum), only its
        // profile changes: the tight measured rim opens into a smooth glow,
        // its edge loses every trace of the kernel's ripples, and a flat
        // highlight still blurs to itself, so it stays untouched.
        plan.halSoftK.clear();
        a.halSoftR = 0;
        const float soft = std::min(std::max(s.halSoftness, 0.0f), 1.0f);
        const float sig = soft * 1.5f * HX_R * scale;   // up to 1.5 x the kernel radius
        if (sig > 0.35f) {
            const int SR = (int)std::ceil(3.0f * sig);
            a.halSoftR = SR;
            plan.halSoftK.resize(2 * SR + 1);
            double sum = 0.0;
            for (int i = -SR; i <= SR; ++i) sum += plan.halSoftK[i + SR] = std::exp(-0.5f * i * i / (sig * sig));
            for (float& v : plan.halSoftK) v = (float)(v / sum);
        }
        a.halS = s.halStrength;
        a.halThr = s.halThreshold;
        const float w = std::min(std::max(s.halWarmth, -1.0f), 1.0f);
        a.kw0 = HX_K[0];
        a.kw1 = HX_K[1] * (1.0f - 0.5f * w);
        a.kw2 = HX_K[2] * (1.0f - 0.5f * w);
    }

    // ---- grain kernel (scaled to the frame height)
    plan.grK.clear();
    a.grR = 0;
    if (a.grOn) {
        const int g = s.gauge == 0 ? 0 : 1;
        const float* U = g == 0 ? GX_U65 : GX_U35;
        const int UR = g == 0 ? 2 : 3;
        const float sc = std::min(std::max(s.size, 0.25f), 4.0f) * (float)H / 2160.0f;
        auto u = [&](float t) {
            t += UR;
            const int k = (int)std::floor(t);
            const float f = t - k;
            float v = 0.0f;
            if (k >= 0 && k <= 2 * UR) v += U[k] * (1.0f - f);
            if (k + 1 >= 0 && k + 1 <= 2 * UR) v += U[k + 1] * f;
            return v;
        };
        // below UHD the film grain field is decimated (measured: white grain at
        // HD for these gauges), hence point sampling of the kernel.
        const int R0 = std::max(0, (int)std::ceil((UR + 0.5f) * sc + 0.5f));
        std::vector<float> k0(2 * R0 + 1);
        for (int i = -R0; i <= R0; ++i) k0[i + R0] = u(i / sc);
        const float sg = std::min(std::max(s.soft, 0.0f), 1.0f) * 2.0f * (float)H / 2160.0f;   // up to 2 px at UHD
        int R = R0;
        if (sg > 0.3f) {
            const int gr = (int)std::ceil(3.0f * sg);
            R = R0 + gr;
            plan.grK.assign(2 * R + 1, 0.0f);
            for (int i = -R0; i <= R0; ++i)
                for (int j = -gr; j <= gr; ++j) plan.grK[i + j + R] += k0[i + R0] * std::exp(-0.5f * j * j / (sg * sg));
        } else {
            plan.grK = k0;
        }
        double n2 = 0.0;
        for (float v : plan.grK) n2 += (double)v * v;
        const float nn = n2 > 0.0 ? (float)(1.0 / std::sqrt(n2)) : 1.0f;
        for (float& v : plan.grK) v *= nn;
        const float t = std::min(std::max(std::log2((float)H / 2160.0f), -1.0f), 0.0f);   // 0 at UHD, -1 at HD
        const float A = 1.0f + (GX_AHD[g] - 1.0f) * (-t);
        a.grR = R;
        a.grScale = s.amount * A;
        a.grSat = std::min(std::max(s.colour, 0.0f), 2.0f);
        a.grSh = std::max(s.shadows, 0.0f);
        a.grMd = std::max(s.midtones, 0.0f);
        a.grHi = std::max(s.highlights, 0.0f);
    }
}

void textureCPU(const TexturePlan& plan, const float* src, ptrdiff_t srcRow, float* dst, ptrdiff_t dstRow)
{
    const TexArgs& A = plan.a;
    const int W = A.W, H = A.H;
    auto px = [&](int x, int y) { return src + (ptrdiff_t)y * srcRow + (ptrdiff_t)x * 4; };

    // ---- halation: source, (half grid), separable blur
    std::vector<float> S, Sd, tmp6, Bg;
    if (A.halOn) {
        S.resize((size_t)W * H);
        parallelRows(H, [&](int y) {
            for (int x = 0; x < W; ++x) {
                const float* p = px(x, y);
                const float Y = A.Yr * tx_decode(A.oetf, p[0]) + A.Yg * tx_decode(A.oetf, p[1]) + A.Yb * tx_decode(A.oetf, p[2]);
                S[(size_t)y * W + x] = tx_halSource(Y, A.halThr);
            }
        });
        const int W2 = A.W2, H2 = A.H2, R = A.halR, N = 2 * R + 1;
        const float* G = S.data();
        if (A.halfRes) {
            Sd.resize((size_t)W2 * H2);
            parallelRows(H2, [&](int y) {
                for (int x = 0; x < W2; ++x) {
                    const int x0 = std::min(2 * x, W - 1), x1 = std::min(2 * x + 1, W - 1);
                    const int y0 = std::min(2 * y, H - 1), y1 = std::min(2 * y + 1, H - 1);
                    Sd[(size_t)y * W2 + x] = ((S[(size_t)y0 * W + x0] + S[(size_t)y0 * W + x1]) +
                                              (S[(size_t)y1 * W + x0] + S[(size_t)y1 * W + x1])) * 0.25f;
                }
            });
            G = Sd.data();
        }
        tmp6.resize((size_t)6 * W2 * H2);
        parallelRows(H2, [&](int y) {
            for (int x = 0; x < W2; ++x)
                for (int r = 0; r < 6; ++r) {
                    const float* k = &plan.halK[(size_t)r * N];
                    float a = 0.0f;
                    for (int i = -R; i <= R; ++i) a += k[i + R] * G[(size_t)y * W2 + clampi(x + i, 0, W2 - 1)];
                    tmp6[((size_t)r * H2 + y) * W2 + x] = a;
                }
        });
        Bg.resize((size_t)W2 * H2);
        parallelRows(H2, [&](int y) {
            for (int x = 0; x < W2; ++x) {
                float b = 0.0f;
                for (int r = 0; r < 6; ++r) {
                    const float* k = &plan.halK[(size_t)r * N];
                    float a = 0.0f;
                    for (int j = -R; j <= R; ++j) a += k[j + R] * tmp6[((size_t)r * H2 + clampi(y + j, 0, H2 - 1)) * W2 + x];
                    b += a * A.halNorm[r];
                }
                // with Softness, the HALO itself (the excess over the pixel's own
                // source) is what gets diffused: its total light is then kept.
                Bg[(size_t)y * W2 + x] = A.halSoftR > 0 ? std::max(b - G[(size_t)y * W2 + x], 0.0f) : b;
            }
        });
        if (A.halSoftR > 0) {
            const int SR = A.halSoftR;
            const float* k = plan.halSoftK.data();
            float* tmp = tmp6.data();   // the first plane is free again
            parallelRows(H2, [&](int y) {
                for (int x = 0; x < W2; ++x) {
                    float a = 0.0f;
                    for (int i = -SR; i <= SR; ++i) a += k[i + SR] * Bg[(size_t)y * W2 + clampi(x + i, 0, W2 - 1)];
                    tmp[(size_t)y * W2 + x] = a;
                }
            });
            parallelRows(H2, [&](int y) {
                for (int x = 0; x < W2; ++x) {
                    float a = 0.0f;
                    for (int j = -SR; j <= SR; ++j) a += k[j + SR] * tmp[(size_t)clampi(y + j, 0, H2 - 1) * W2 + x];
                    Bg[(size_t)y * W2 + x] = a;
                }
            });
        }
    }

    // ---- grain: horizontal pass over a band padded by R rows top and bottom
    std::vector<float> T;
    const int GR = A.grR, Hp = H + 2 * GR;
    if (A.grOn) {
        T.resize((size_t)3 * W * Hp);
        parallelRows(Hp, [&](int yy) {
            const int y = yy - GR;
            std::vector<float> nrow((size_t)W + 2 * GR);   // the row's noise, drawn once per pixel
            for (int c = 0; c < 3; ++c) {
                const unsigned int sd = A.seed + (unsigned int)c * GX_CH_SEED;
                for (int x = -GR; x < W + GR; ++x) nrow[(size_t)(x + GR)] = tx_gauss(x, y, sd);
                for (int x = 0; x < W; ++x) {
                    float a = 0.0f;
                    for (int i = -GR; i <= GR; ++i) a += plan.grK[i + GR] * nrow[(size_t)(x + i + GR)];
                    T[((size_t)c * Hp + yy) * W + x] = a;
                }
            }
        });
    }

    // ---- per pixel
    parallelRows(H, [&](int y) {
        float* d = dst + (ptrdiff_t)y * dstRow;
        float B = 0.0f;
        int y0 = 0, y1 = 0;
        float wy = 0.0f;
        if (A.halOn && A.halfRes) {
            const float fy = (y + 0.5f) * 0.5f - 0.5f;
            y0 = clampi((int)std::floor(fy), 0, A.H2 - 1);
            y1 = std::min(y0 + 1, A.H2 - 1);
            wy = std::min(std::max(fy - y0, 0.0f), 1.0f);
        }
        for (int x = 0; x < W; ++x, d += 4) {
            const float* p = px(x, y);
            TxRGB c = {tx_decode(A.oetf, p[0]), tx_decode(A.oetf, p[1]), tx_decode(A.oetf, p[2])};
            const TxRGB c0 = c;
            float S0 = 0.0f;
            if (A.halOn) {
                S0 = S[(size_t)y * W + x];
                if (A.halfRes) {
                    const float fx = (x + 0.5f) * 0.5f - 0.5f;
                    const int x0 = clampi((int)std::floor(fx), 0, A.W2 - 1), x1 = std::min(x0 + 1, A.W2 - 1);
                    const float wx = std::min(std::max(fx - x0, 0.0f), 1.0f);
                    const float a = Bg[(size_t)y0 * A.W2 + x0] * (1.0f - wx) + Bg[(size_t)y0 * A.W2 + x1] * wx;
                    const float b = Bg[(size_t)y1 * A.W2 + x0] * (1.0f - wx) + Bg[(size_t)y1 * A.W2 + x1] * wx;
                    B = a * (1.0f - wy) + b * wy;
                } else {
                    B = Bg[(size_t)y * W + x];
                }
            }
            float z[3] = {0.0f, 0.0f, 0.0f};
            if (A.grOn)
                for (int ch = 0; ch < 3; ++ch) {
                    float a = 0.0f;
                    for (int j = 0; j <= 2 * GR; ++j) a += plan.grK[j] * T[((size_t)ch * Hp + y + j) * W + x];
                    z[ch] = a;
                }
            if (A.halSoftR > 0) S0 = 0.0f;   // B already is the (diffused) halo
            c = tx_pixel(A.halOn, A.halS, A.kw0, A.kw1, A.kw2, A.grOn, A.grScale, A.grSat, A.grSh, A.grMd, A.grHi,
                         A.Yr, A.Yg, A.Yb, c, S0, B, z[0], z[1], z[2]);
            d[0] = c.r == c0.r ? p[0] : p[0] + (tx_encode(A.oetf, c.r) - tx_encode(A.oetf, c0.r));
            d[1] = c.g == c0.g ? p[1] : p[1] + (tx_encode(A.oetf, c.g) - tx_encode(A.oetf, c0.g));
            d[2] = c.b == c0.b ? p[2] : p[2] + (tx_encode(A.oetf, c.b) - tx_encode(A.oetf, c0.b));
            d[3] = p[3];
        }
    });
}

} // namespace nodeone
