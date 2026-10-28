// Texture stage checks (CPU): log curve roundtrips, bit-exact pass-through,
// grain strength against the measured table, halation behaviour.
#include "NodeTexture.h"
#include <cstdio>
#include <cmath>
#include <vector>
#include <algorithm>
using namespace nodeone;
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { ++fails; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main()
{
    // 1. encode(decode(x)) roundtrip for every curve, over the scene range
    for (int tf = 0; tf <= 9; ++tf) {
        double worst = 0;
        for (int i = 0; i <= 4000; ++i) {
            const float l = (float)(-0.01 + std::pow(10.0, -4.0 + 6.5 * i / 4000.0));   // ~-0.01 .. 300
            const float x = tx_encode(tf, l);
            const float l2 = tx_decode(tf, x);
            worst = std::max(worst, (double)std::fabs(l2 - l) / std::max(1e-3, (double)std::fabs(l)));
        }
        printf("curve %d  roundtrip worst rel err %.2e\n", tf, worst);
        CHECK(worst < 2e-5, "curve %d roundtrip", tf);
    }
    // decode then encode on code values
    for (int tf = 1; tf <= 9; ++tf) {
        double worst = 0;
        for (int i = 0; i <= 1000; ++i) {
            float x = 0.12f + 0.8f * i / 1000.0f;
            worst = std::max(worst, (double)std::fabs(tx_encode(tf, tx_decode(tf, x)) - x));
        }
        CHECK(worst < 3e-6, "curve %d code roundtrip %.2e", tf, worst);
    }

    const int W = 960, H = 540;
    std::vector<float> img((size_t)W * H * 4), out(img.size());
    // a DI ramp with a bright disc
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            float* p = &img[((size_t)y * W + x) * 4];
            const float v = 0.15f + 0.45f * x / (W - 1);
            const float r2 = (float)((x - 700) * (x - 700) + (y - 270) * (y - 270));
            const float d = r2 < 40 * 40 ? 0.85f : v;
            p[0] = d; p[1] = d * 0.98f; p[2] = d * 0.95f; p[3] = 1.0f;
        }

    // 2. inactive and zero-effect settings
    TextureSettings s;
    CHECK(!s.active(), "default must be inactive");
    s.halOn = true; s.halStrength = 1.0f; s.halThreshold = 0.2f;
    std::vector<float> flat(img.size());
    for (size_t i = 0; i < flat.size(); i += 4) { flat[i] = flat[i + 1] = flat[i + 2] = 0.3f; flat[i + 3] = 1; }
    TexturePlan pl;
    texturePlan(s, W, H, pl);
    textureCPU(pl, flat.data(), W * 4, out.data(), W * 4);
    CHECK(std::equal(flat.begin(), flat.end(), out.begin()), "halation below threshold must be bit exact");

    // 3. grain statistics on flat DI greys (DWG / DI, 35mm, UHD-equivalent amount)
    for (int g = 0; g < 2; ++g) {
        const int W4 = 1280, H4 = 2160;   // UHD height: amplitude factor 1
        std::vector<float> f((size_t)W4 * H4 * 4), o(f.size());
        TextureSettings gs; gs.grainOn = true; gs.gauge = g; gs.gamut = 15; gs.oetf = 1; gs.seed = 7;
        TexturePlan gp; texturePlan(gs, W4, H4, gp);
        for (float dv : {0.20f, 0.336f, 0.48f, 0.64f}) {
            for (size_t i = 0; i < f.size(); i += 4) { f[i] = f[i + 1] = f[i + 2] = dv; f[i + 3] = 1; }
            textureCPU(gp, f.data(), W4 * 4, o.data(), W4 * 4);
            double m[3] = {0, 0, 0}, v[3] = {0, 0, 0}, crg = 0; const size_t n = (size_t)W4 * H4;
            for (size_t i = 0; i < n; ++i) for (int c = 0; c < 3; ++c) m[c] += o[i * 4 + c] - dv;
            for (int c = 0; c < 3; ++c) m[c] /= n;
            for (size_t i = 0; i < n; ++i) { for (int c = 0; c < 3; ++c) { double e = o[i * 4 + c] - dv - m[c]; v[c] += e * e; } crg += (o[i*4]-dv-m[0])*(o[i*4+1]-dv-m[1]); }
            double sd[3]; for (int c = 0; c < 3; ++c) sd[c] = std::sqrt(v[c] / n);
            // ev of this grey decides the zone weight (all 1 here) -> std must match the table
            double want[3]; for (int c = 0; c < 3; ++c) want[c] = tx_grainSig(c, dv);
            printf("gauge %s DI %.3f  std %.4f %.4f %.4f  (table %.4f %.4f %.4f)  rRG %.2f  mean %.1e\n", g ? "35" : "65", dv,
                   sd[0], sd[1], sd[2], want[0], want[1], want[2], crg / n / (sd[0] * sd[1]), m[1]);
            for (int c = 0; c < 3; ++c) CHECK(std::fabs(sd[c] / (0.75 * want[c]) - 1) < 0.08, "grain std ch%d DI %.3f", c, dv);
        }
    }

    // 4. halation: glow outside the disc, red > green > blue, flat highlight untouched
    s = TextureSettings(); s.halOn = true; s.gamut = 15; s.oetf = 1;
    texturePlan(s, W, H, pl);
    textureCPU(pl, img.data(), W * 4, out.data(), W * 4);
    auto at = [&](std::vector<float>& b, int x, int y, int c) { return b[((size_t)y * W + x) * 4 + c]; };
    const int xs = 700 + 41, ys = 270;   // just outside the disc
    const float dr = at(out, xs, ys, 0) - at(img, xs, ys, 0), dg = at(out, xs, ys, 1) - at(img, xs, ys, 1), db = at(out, xs, ys, 2) - at(img, xs, ys, 2);
    printf("halation just outside: dR %.4f dG %.4f dB %.4f\n", dr, dg, db);
    CHECK(dr > 0.005f && dr > dg && dg > db && db >= 0, "halation colour order");
    CHECK(at(out, 700, 270, 0) == at(img, 700, 270, 0), "centre of the disc must be untouched");
    CHECK(at(out, 50, 50, 0) == at(img, 50, 50, 0), "far pixel untouched");
    // falloff
    for (int r = 38; r < 52; ++r) printf("  r=%d dR %.5f\n", r, at(out, 700 + r, 270, 0) - at(img, 700 + r, 270, 0));

    // 5. halation softness: same total halo light, smoother (no ripple), flat areas untouched
    {
        auto haloSum = [&](float soft, std::vector<float>& o, float& peak) {
            TextureSettings hs; hs.halOn = true; hs.gamut = 15; hs.oetf = 1; hs.halSoftness = soft;
            TexturePlan hp; texturePlan(hs, W, H, hp);
            textureCPU(hp, img.data(), W * 4, o.data(), W * 4);
            double sum = 0; peak = 0;
            for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
                const float d = tx_decode(1, o[((size_t)y * W + x) * 4]) - tx_decode(1, img[((size_t)y * W + x) * 4]);
                const float dx = x - 700.f, dy = y - 270.f;
                sum += tx_halT(tx_decode(1, o[((size_t)y * W + x) * 4])) - tx_halT(tx_decode(1, img[((size_t)y * W + x) * 4]));
                if (dx * dx + dy * dy >= 40.f * 40.f) peak = std::max(peak, d);
            }
            return sum;
        };
        std::vector<float> o0(img.size()), o1(img.size());
        float p0, p1;
        const double s0 = haloSum(0.0f, o0, p0), s1 = haloSum(1.0f, o1, p1);
        printf("halation softness: halo (T domain) %.1f -> %.1f, peak %.4f -> %.4f\n", s0, s1, p0, p1);
        CHECK(p1 < p0, "softness lowers the rim peak");
        CHECK(std::fabs(s1 / s0 - 1.0) < 0.05, "softness keeps the halo's light (%.2f)", s1 / s0);
        CHECK(o1[((size_t)270 * W + 700) * 4] == img[((size_t)270 * W + 700) * 4], "softness: disc centre untouched");
        CHECK(o1[((size_t)50 * W + 50) * 4] == img[((size_t)50 * W + 50) * 4], "softness: far pixel untouched");
        float prev = 1e9f; bool mono = true;
        for (int r = 41; r < 75; ++r) { float d = o1[((size_t)270 * W + 700 + r) * 4] - img[((size_t)270 * W + 700 + r) * 4]; if (d > prev + 1e-6f) mono = false; prev = d; }
        CHECK(mono, "soft halo falls off monotonically");
        for (int r = 38; r < 60; r += 3) printf("  soft r=%d dR %.5f\n", r, o1[((size_t)270 * W + 700 + r) * 4] - img[((size_t)270 * W + 700 + r) * 4]);
    }

    printf(fails ? "\n%d FAILURES\n" : "\nALL OK\n", fails);
    return fails ? 1 : 0;
}
