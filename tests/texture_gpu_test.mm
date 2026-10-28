// GPU vs CPU check of the whole Node DRT render with the Texture stage on.
// Build (from the repo root, after ./build.sh):
//   clang++ -std=c++17 -O2 -fobjc-arc -Isrc/core -Igen -Iopenfx/include -Iopenfx/Support/include \
//     tests/texture_gpu_test.mm $(ls build/obj/*.o | grep -v bundle_drt_main) -framework Metal -framework Foundation -o build/texture_gpu_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
#include "NodeOneMetal.h"
#include "NodeOnePlugin.h"
#include "NodeTexture.h"
namespace nodeone { extern const PluginDef kPlugin_drt; }
using namespace nodeone;

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
        int fails = 0;
        const int sizes[2][2] = {{1920, 1080}, {3840, 2160}};
        for (int si = 0; si < 2; ++si) {
            const int W = sizes[si][0], H = sizes[si][1];
            std::vector<float> img((size_t)W * H * 4);
            for (int y = 0; y < H; ++y)
                for (int x = 0; x < W; ++x) {
                    float* p = &img[((size_t)y * W + x) * 4];
                    const float v = 0.1f + 0.6f * x / (W - 1);
                    const float dx = x - W * 0.6f, dy = y - H * 0.5f;
                    const bool disc = dx * dx + dy * dy < (H * 0.06f) * (H * 0.06f);
                    p[0] = disc ? 0.9f : v; p[1] = disc ? 0.88f : v * 0.97f; p[2] = disc ? 0.85f : v * 0.9f; p[3] = 1;
                }
            for (int mode = 0; mode < 4; ++mode) {
                TextureSettings s;
                s.grainOn = mode == 1 || mode == 3; s.gauge = si ? 0 : 1; s.soft = mode == 3 ? 0.6f : 0.0f;
                s.halOn = mode >= 2; s.halSize = mode == 3 ? 2.0f : 1.0f; s.seed = 1234;
                TexturePlan plan;
                if (s.active()) texturePlan(s, W, H, plan);
                id<MTLBuffer> src = [dev newBufferWithBytes:img.data() length:img.size() * 4 options:MTLResourceStorageModeShared];
                id<MTLBuffer> dst = [dev newBufferWithLength:img.size() * 4 options:MTLResourceStorageModeShared];
                MetalScratch* sc = metalScratchCreate();
                MetalJob j{};
                j.def = &def; j.params = block.data(); j.lut = nullptr; j.scratch = sc;
                j.commandQueue = (__bridge void*)q; j.srcBuffer = (__bridge void*)src; j.dstBuffer = (__bridge void*)dst;
                j.width = W; j.height = H; j.srcRowFloats = W * 4; j.dstRowFloats = W * 4; j.flipY = 1;
                j.texture = s.active() ? &plan : nullptr;
                std::string err;
                NSDate* t0 = [NSDate date];
                if (!metalRender(j, err)) { printf("metalRender failed: %s\n", err.c_str()); return 1; }
                id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted];
                const double gms = -[t0 timeIntervalSinceNow] * 1000;
                // CPU reference
                std::vector<float> tex(img.size()), ref(img.size());
                const float* in = img.data();
                if (s.active()) { textureCPU(plan, img.data(), W * 4, tex.data(), W * 4); in = tex.data(); }
                cpuRender(def, block.data(), in, W * 4, ref.data(), W * 4, W, H, 0, H, 1);
                const float* g = (const float*)dst.contents;
                double worst = 0, sum = 0;
                for (size_t i = 0; i < ref.size(); ++i) { double d = std::fabs(g[i] - ref[i]); worst = std::max(worst, d); sum += d; }
                // texture effect size vs the plain render
                std::vector<float> plain(img.size());
                cpuRender(def, block.data(), img.data(), W * 4, plain.data(), W * 4, W, H, 0, H, 1);
                double eff = 0; for (size_t i = 0; i < ref.size(); ++i) eff = std::max(eff, (double)std::fabs(ref[i] - plain[i]));
                printf("%dx%d mode %d  GPU vs CPU max %.2e mean %.2e  | effect max %.3f | gpu %.1f ms\n", W, H, mode, worst,
                       sum / ref.size(), eff, gms);
                if (worst > 2e-3) ++fails;
                if (mode == 0 && worst != 0) printf("  note: texture off differs\n");
                metalScratchDestroy(sc);
            }
        }
        printf(fails ? "FAILED\n" : "GPU OK\n");
        return fails;
    }
}
