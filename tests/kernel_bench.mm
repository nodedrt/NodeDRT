// Node DRT — times one generated Metal kernel source (profiling aid).
// Build: clang++ -std=c++17 -O2 -fobjc-arc -Isrc/core -Igen -Iopenfx/include -Iopenfx/Support/include \
//   tests/kernel_bench.mm tests/ofx_stub.cpp $(ls build/obj/*.o | grep -v bundle_drt_main) \
//   -framework Metal -framework Foundation -o build/kernel_bench
// Usage: build/kernel_bench file.metal [name=value ...]   (UHD, GPU time from command-buffer timestamps)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include "NodeOnePlugin.h"
namespace nodeone { extern const PluginDef kPlugin_drt; }
using namespace nodeone;

int main(int argc, char** argv)
{
    @autoreleasepool {
        if (argc < 2) return 2;
        const PluginDef& def = kPlugin_drt;
        const int W = getenv("BW") ? atoi(getenv("BW")) : 3840, H = getenv("BH") ? atoi(getenv("BH")) : 2160;
        std::vector<uint32_t> block(def.paramsSize / 4, 0u);
        for (int i = 0; i < def.nParams; ++i) {
            const ParamSpec& p = def.params[i];
            if (p.offset >= kPluginOnly) continue;
            if (p.kind == kParamFloat) { float v = (float)p.def; std::memcpy(&block[p.offset / 4], &v, 4); }
            else { int32_t v = (int32_t)std::lround(p.def); std::memcpy(&block[p.offset / 4], &v, 4); }
        }
        for (int a = 2; a < argc; ++a) {
            std::string t = argv[a];
            size_t e = t.find('=');
            if (e == std::string::npos) continue;
            std::string n = t.substr(0, e); double v = atof(t.c_str() + e + 1);
            for (int i = 0; i < def.nParams; ++i) {
                const ParamSpec& p = def.params[i];
                if (n != p.name || p.offset >= kPluginOnly) continue;
                if (p.kind == kParamFloat) { float f = (float)v; std::memcpy(&block[p.offset / 4], &f, 4); }
                else { int32_t k = (int32_t)std::lround(v); std::memcpy(&block[p.offset / 4], &k, 4); }
            }
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSString* src = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
        MTLCompileOptions* o = [MTLCompileOptions new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        o.fastMathEnabled = getenv("FASTMATH") ? YES : NO;
#pragma clang diagnostic pop
        NSError* err = nil;
        NSDate* c0 = [NSDate date];
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&err];
        const double compileS = -[c0 timeIntervalSinceNow];
        if (!lib) { printf("COMPILE FAIL %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"node_one_main"] error:&err];
        if (!pso) { printf("PSO FAIL\n"); return 1; }
        std::vector<float> img((size_t)W * H * 4);
        unsigned s = 12345u;
        for (int y = 0; y < H; ++y)
            for (int x = 0; x < W; ++x) {
                float* p = &img[((size_t)y * W + x) * 4];
                s = s * 1664525u + 1013904223u;
                const float n = ((s >> 9) & 0xFFFF) / 65535.0f * 0.02f;
                const float u = (float)x / (W - 1), v = (float)y / (H - 1);
                float r = 0.08f + 0.75f * u, g = r * (0.9f + 0.2f * v), b = r * (1.1f - 0.4f * v);
                const float dx = x - W * 0.35f, dy = y - H * 0.45f;
                if (dx * dx + dy * dy < (H * 0.18f) * (H * 0.18f)) { r = 0.52f; g = 0.42f; b = 0.36f; }
                if (y < H / 10) { r = 0.98f; g = 0.95f; b = 0.9f; }
                if (x > W * 0.85f) { r = 0.2f + 0.6f * v; g = 0.15f; b = 0.55f - 0.3f * v; }
                p[0] = r + n; p[1] = g + n; p[2] = b + n; p[3] = 1.0f;
            }
        id<MTLBuffer> in = [dev newBufferWithBytes:img.data() length:img.size() * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:img.size() * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        struct { int32_t w, h, rs, rd, flip, a, b, c; } D = {W, H, W * 4, W * 4, 1, 0, 0, 0};
        std::vector<double> t;
        for (int it = 0; it < 15; ++it) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBytes:block.data() length:def.paramsSize atIndex:0];
            [enc setBuffer:in offset:0 atIndex:1];
            [enc setBuffer:out offset:0 atIndex:2];
            [enc setBytes:&D length:sizeof(D) atIndex:3];
            const NSUInteger tw = pso.threadExecutionWidth;
            const NSUInteger th = MAX((NSUInteger)1, pso.maxTotalThreadsPerThreadgroup / tw);
            const MTLSize tg = MTLSizeMake(tw, MIN(th, (NSUInteger)8), 1);
            [enc dispatchThreadgroups:MTLSizeMake((W + tg.width - 1) / tg.width, (H + tg.height - 1) / tg.height, 1) threadsPerThreadgroup:tg];
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            if (it >= 3) t.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0);
        }
        std::sort(t.begin(), t.end());
        const float* r = (const float*)out.contents;
        double sum = 0; for (size_t i = 0; i < img.size(); i += 7) sum += r[i];
        printf("%.2f ms  (tg max %lu, compile %.2fs)  checksum %.6f\n", t[t.size() / 2],
               (unsigned long)pso.maxTotalThreadsPerThreadgroup, compileS, sum);
        if (getenv("DUMP")) { FILE* f = fopen(getenv("DUMP"), "wb"); fwrite(r, 4, img.size(), f); fclose(f); }
    }
    return 0;
}
