// Density Pro: GPU vs CPU, and its cost on the GPU, through the plugin's own
// render path (metalRender).
// Build (from the repo root, after ./build.sh):
//   clang++ -std=c++17 -O2 -fobjc-arc -Isrc/core -Igen -Iopenfx/include -Iopenfx/Support/include \
//     tests/density_gpu_test.mm tests/ofx_stub.cpp $(ls build/obj/*.o | grep -v bundle_drt_main) \
//     -framework Metal -framework Foundation -o build/density_gpu_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
#include "NodeOneMetal.h"
#include "NodeOnePlugin.h"
#include "NodeDensity.h"
namespace nodeone { extern const PluginDef kPlugin_drt; }
using namespace nodeone;

static void setP(const PluginDef& def, std::vector<uint32_t>& b, const char* n, int v)
{
    for (int i = 0; i < def.nParams; ++i)
        if (!std::strcmp(def.params[i].name, n) && def.params[i].offset < kPluginOnly) std::memcpy(&b[def.params[i].offset / 4], &v, 4);
}

int main()
{
    @autoreleasepool {
        const PluginDef& def = kPlugin_drt;
        std::vector<uint32_t> block(def.paramsSize / 4, 0u);
        for (int i = 0; i < def.nParams; ++i) {
            const ParamSpec& p = def.params[i];
            if (p.offset >= kPluginOnly) continue;
            if (p.kind == kParamFloat) { float v = (float)p.def; std::memcpy(&block[p.offset / 4], &v, 4); }
            else { int32_t v = (int32_t)std::lround(p.def); std::memcpy(&block[p.offset / 4], &v, 4); }
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const int W = 3840, H = 2160;
        std::vector<float> img((size_t)W * H * 4);
        for (int y = 0; y < H; ++y)
            for (int x = 0; x < W; ++x) {
                float* p = &img[((size_t)y * W + x) * 4];
                const float h = 6.2831853f * x / W, v = (float)y / H;
                p[0] = 0.15f + 0.7f * v + 0.12f * std::cos(h);
                p[1] = 0.15f + 0.7f * v + 0.12f * std::cos(h - 2.094f);
                p[2] = 0.15f + 0.7f * v + 0.12f * std::cos(h + 2.094f);
                p[3] = 1.0f;
            }
        id<MTLBuffer> src = [dev newBufferWithBytes:img.data() length:img.size() * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> dst = [dev newBufferWithLength:img.size() * 4 options:MTLResourceStorageModeShared];
        int fails = 0;
        for (int mode = -1; mode < 5; ++mode) {
            DensitySettings s;
            s.on = true;
            s.zone[0] = 40; s.zone[2] = -30; s.hue[0] = 60; s.hue[3] = -50; s.hue[4] = 80; s.range[4] = 2.0f;
            if (mode == 1) { s.boost = 60; s.colorsSmooth = 1.0f; s.zonesSmooth = 1.0f; }
            if (mode == 2) { s.show = true; s.maskFocus = 4; }
            if (mode == 3) { s.gamut = 5; s.oetf = 3; }   // Rec.709 / ACEScct input: converted there and back
            if (mode == 4) { s.colorsSmooth = 0.0f; s.zonesSmooth = 0.5f; }
            std::vector<uint32_t> b = block;
            setP(def, b, "in_gamut", s.gamut);
            setP(def, b, "in_oetf", s.oetf);
            DensityPlan plan;
            densityPlan(s, W, H, plan);
            MetalScratch* sc = metalScratchCreate();
            MetalJob j{};
            j.def = &def; j.params = b.data(); j.scratch = sc;
            j.commandQueue = (__bridge void*)q; j.srcBuffer = (__bridge void*)src; j.dstBuffer = (__bridge void*)dst;
            j.width = W; j.height = H; j.srcRowFloats = W * 4; j.dstRowFloats = W * 4; j.flipY = 1;
            j.density = mode >= 0 ? &plan : nullptr;
            std::string err;
            metalRender(j, err);
            [NSThread sleepForTimeInterval:1.5];
            metalRender(j, err);
            { id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
            NSDate* t0 = [NSDate date];
            for (int f = 0; f < 20; ++f) metalRender(j, err);
            { id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
            const double ms = -[t0 timeIntervalSinceNow] * 1000.0 / 20;
            // CPU reference: Density Pro then the DCTL
            std::vector<float> den(img.size()), ref(img.size()), plain(img.size());
            if (mode >= 0) densityCPU(plan, img.data(), W * 4, den.data(), W * 4); else den = img;
            cpuRender(def, b.data(), den.data(), W * 4, ref.data(), W * 4, W, H, 0, H, 1);
            cpuRender(def, b.data(), img.data(), W * 4, plain.data(), W * 4, W, H, 0, H, 1);
            const float* g = (const float*)dst.contents;
            double worst = 0, eff = 0;
            for (size_t i = 0; i < ref.size(); ++i) {
                worst = std::max(worst, (double)std::fabs(g[i] - ref[i]));
                eff = std::max(eff, (double)std::fabs(ref[i] - plain[i]));
            }
            printf("mode %d  GPU vs CPU max %.2e | effect max %.3f | %.2f ms/frame (UHD, DRT included)\n", mode, worst, eff, ms);
            if (worst > 2e-3) ++fails;
            metalScratchDestroy(sc);
        }
        printf(fails ? "FAILED\n" : "OK\n");
        return fails ? 1 : 0;
    }
}
