// Node DRT v2: GPU (metalRender, specialised kernels) vs CPU (cpuRender), per scenario.
// Build (from the repo root, after ./build.sh):
//   clang++ -std=c++17 -O2 -fobjc-arc -Isrc/core -Igen -Iopenfx/include -Iopenfx/Support/include \
//     tests/gpu_cpu_test.mm tests/ofx_stub.cpp $(ls build/obj/*.o | grep -v bundle_drt_main) \
//     -framework Metal -framework Foundation -o build/gpu_cpu_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "NodeOneMetal.h"
#include "NodeOnePlugin.h"
namespace nodeone { extern const PluginDef kPlugin_drt; }
using namespace nodeone;

static void setParam(const PluginDef& def, std::vector<uint32_t>& block, const std::string& n, double v)
{
    for (int i = 0; i < def.nParams; ++i) {
        const ParamSpec& p = def.params[i];
        if (n != p.name) continue;
        if (p.offset >= kPluginOnly) return;
        if (p.kind == kParamFloat) { float f = (float)v; std::memcpy(&block[p.offset / 4], &f, 4); }
        else { int32_t k = (int32_t)std::lround(v); std::memcpy(&block[p.offset / 4], &k, 4); }
        return;
    }
    fprintf(stderr, "unknown param %s\n", n.c_str()); exit(2);
}

int main()
{
    @autoreleasepool {
        const int W = 1920, H = 1080;
        const PluginDef& def = kPlugin_drt;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        std::vector<float> img((size_t)W * H * 4);
        unsigned s = 12345u;
        for (int y = 0; y < H; ++y)
            for (int x = 0; x < W; ++x) {
                float* p = &img[((size_t)y * W + x) * 4];
                s = s * 1664525u + 1013904223u;
                const float n = (((s >> 9) & 0xFFFF) / 65535.0f - 0.5f) * 0.03f;
                const float u = (float)x / (W - 1), v = (float)y / (H - 1);
                float r = 0.02f + 0.9f * u, g = r * (0.9f + 0.2f * v), b = r * (1.1f - 0.4f * v);
                const float dx = x - W * 0.35f, dy = y - H * 0.45f;
                if (dx * dx + dy * dy < (H * 0.18f) * (H * 0.18f)) { r = 0.52f; g = 0.42f; b = 0.36f; }
                if (y < H / 10) { r = 0.98f; g = 0.95f; b = 0.9f; }
                if (x > W * 0.85f) { r = 0.2f + 0.6f * v; g = 0.15f; b = 0.55f - 0.3f * v; }
                if (y > H * 0.9f) { r = 0.01f * u; g = 0.0f; b = 0.02f * v; }   // noisy black floor
                p[0] = r + n; p[1] = g + n; p[2] = b + n; p[3] = 1.0f;
            }
        id<MTLBuffer> src = [dev newBufferWithBytes:img.data() length:img.size() * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> dst = [dev newBufferWithLength:img.size() * 4 options:MTLResourceStorageModeShared];
        const char* sc[] = {
            "", "look_preset=1", "look_preset=2", "look_preset=3", "look_preset=4", "look_preset=5", "look_preset=6", "look_preset=7",
            "look_preset=4 tonescale_preset=1", "look_preset=1 look_intensity=0.5",
            "look_preset=1 trim_sh=1", "look_preset=4 trim_sh=-1", "look_preset=1 trim_con=-0.5 trim_ovl=-1",
            "look_preset=5 col_dens=1 col_weight=1", "look_preset=5 trim_br=-1",
            "look_preset=1 trim_skin=1 trim_skin_sat=-1 skin_mid=0.8",
            "look_preset=1 trim_skin_sat=0.5 skin_hi=0.5 skin_mhc=0.6",
            "look_preset=1 skin_zones=1 skin_mhc=-0.5 skin_medge=0.6",
            "look_preset=7 display_encoding_preset=3 tn_Lp=1000",
            "look_preset=1 trim_blift=1 trim_wroll=1 trim_blift_pv=1 trim_wroll_pv=-1.5 trim_sh=0.5", "look_preset=4 trim_blift=0.5 trim_wroll=0.7 display_encoding_preset=3 tn_Lp=1000",
            "look_preset=1 skin_zones=1 trim_skin_sat=0.4", "look_preset=1 skin_mid=0.5 trim_skin_sat=0.5 skin_msl=-0.6 skin_msx=0.7 skin_mdk=-0.5 skin_mhue=-0.4 skin_soft=0.2", "look_preset=1 skin_mid=0.6 skin_medge=1 crv_enable=1 trim_blift=1",
        };
        double worst = 0;
        for (const char* S : sc) {
            std::vector<uint32_t> block(def.paramsSize / 4, 0u);
            for (int i = 0; i < def.nParams; ++i) {
                const ParamSpec& p = def.params[i];
                if (p.offset >= kPluginOnly) continue;
                if (p.kind == kParamFloat) { float v = (float)p.def; std::memcpy(&block[p.offset / 4], &v, 4); }
                else { int32_t v = (int32_t)std::lround(p.def); std::memcpy(&block[p.offset / 4], &v, 4); }
            }
            char buf[512]; std::strncpy(buf, S, sizeof(buf) - 1); buf[sizeof(buf) - 1] = 0;
            for (char* t = std::strtok(buf, " "); t; t = std::strtok(nullptr, " ")) {
                char* e = std::strchr(t, '='); if (!e) continue; *e = 0; setParam(def, block, t, atof(e + 1));
            }
            MetalScratch* scr = metalScratchCreate();
            MetalJob j{};
            j.def = &def; j.params = block.data(); j.lut = nullptr; j.scratch = scr;
            j.commandQueue = (__bridge void*)q; j.srcBuffer = (__bridge void*)src; j.dstBuffer = (__bridge void*)dst;
            j.width = W; j.height = H; j.srcRowFloats = W * 4; j.dstRowFloats = W * 4; j.flipY = 0;
            std::string err;
            for (int w = 0; w < 2; ++w) metalRender(j, err);
            [NSThread sleepForTimeInterval:2.0];      // specialised kernel compiled in the background
            if (!metalRender(j, err)) { printf("render failed: %s\n", err.c_str()); return 1; }
            { id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
            const float* g = (const float*)dst.contents;
            std::vector<float> c(img.size());
            def.cpuRender(block.data(), img.data(), W * 4, c.data(), W * 4, W, H, 0, H, 0);
            double mx = 0; size_t nan = 0;
            for (size_t i = 0; i < img.size(); ++i) {
                if ((i & 3) == 3) continue;
                if (!std::isfinite(g[i]) || !std::isfinite(c[i])) { ++nan; continue; }
                mx = std::max(mx, (double)std::fabs(g[i] - c[i]));
            }
            worst = std::max(worst, mx);
            printf("  %-62s GPU-CPU max %.2e  (%.3f code 10-bit)  nonfinite %zu\n", S[0] ? S : "default", mx, mx * 1023.0, nan);
            metalScratchDestroy(scr);
        }
        printf("worst %.2e\n", worst);
    }
    return 0;
}
