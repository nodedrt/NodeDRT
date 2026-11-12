// Film print looks: GPU vs CPU and cost, through metalRender (as the plugin).
// NODEDRT_FILM_TABLES=resources/film/film_tables.bin build/film_gpu_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
#include "NodeOneMetal.h"
#include "NodeOnePlugin.h"
#include "NodeFilm.h"
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
        int n = 0;
        if (!filmTablesCPU(n)) { printf("no film tables\n"); return 1; }
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
                p[0] = 0.10f + 0.85f * v + 0.10f * std::cos(h);
                p[1] = 0.10f + 0.85f * v + 0.10f * std::cos(h - 2.094f);
                p[2] = 0.10f + 0.85f * v + 0.10f * std::cos(h + 2.094f);
                p[3] = 1.0f;
            }
        id<MTLBuffer> src = [dev newBufferWithBytes:img.data() length:img.size() * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> dst = [dev newBufferWithLength:img.size() * 4 options:MTLResourceStorageModeShared];
        int fails = 0;
        const int cases[][2] = {{0, 0}, {1, 0}, {4, 0}, {7, 0}, {1, 3}, {1, 4}};   // look, display encoding
        for (auto& c : cases) {
            std::vector<uint32_t> b = block;
            setP(def, b, "look_preset", c[0]);
            setP(def, b, "display_encoding_preset", c[1]);
            MetalScratch* sc = metalScratchCreate();
            MetalJob j{};
            j.def = &def; j.params = b.data(); j.scratch = sc;
            j.commandQueue = (__bridge void*)q; j.srcBuffer = (__bridge void*)src; j.dstBuffer = (__bridge void*)dst;
            j.width = W; j.height = H; j.srcRowFloats = W * 4; j.dstRowFloats = W * 4; j.flipY = 1;
            std::string err;
            metalRender(j, err);
            [NSThread sleepForTimeInterval:2.0];
            metalRender(j, err);
            { id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
            NSDate* t0 = [NSDate date];
            for (int f = 0; f < 20; ++f) metalRender(j, err);
            { id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
            const double ms = -[t0 timeIntervalSinceNow] * 1000.0 / 20;
            std::vector<float> ref(img.size());
            cpuRender(def, b.data(), img.data(), W * 4, ref.data(), W * 4, W, H, 0, H, 1);
            const float* g = (const float*)dst.contents;
            double worst = 0, mx = 0, mean = 0;
            for (size_t i = 0; i < ref.size(); ++i) {
                if ((i & 3) == 3) continue;
                worst = std::max(worst, (double)std::fabs(g[i] - ref[i]));
                mx = std::max(mx, (double)ref[i]); mean += ref[i];
            }
            printf("look %d enc %d  GPU vs CPU max %.2e | out max %.3f mean %.3f | %.2f ms/frame UHD\n", c[0], c[1], worst, mx, mean / (ref.size() * 0.75), ms);
            if (worst > 2e-3) ++fails;
            metalScratchDestroy(sc);
        }
        printf(fails ? "FAILED\n" : "OK\n");
        return fails;
    }
}
