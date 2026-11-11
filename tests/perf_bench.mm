// Node DRT — GPU throughput benchmark (same code path as the plugin: metalRender).
// Build (from the repo root, after ./build.sh):
//   clang++ -std=c++17 -O2 -fobjc-arc -Isrc/core -Igen -Iopenfx/include -Iopenfx/Support/include \
//     tests/perf_bench.mm $(ls build/obj/*.o | grep -v bundle_drt_main) -framework Metal -framework Foundation -o build/perf_bench
// Usage: build/perf_bench [W H] [frames]
// Prints ms/frame for a set of scenarios, plus a checksum of the output so two
// builds can be compared picture for picture (bench --dump writes raw floats).
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
#include "NodeTexture.h"
namespace nodeone { extern const PluginDef kPlugin_drt; }
using namespace nodeone;

struct Scenario {
    const char* name;
    const char* sets;   // "name=value name=value"
    int grain;          // 0 off, 1 35mm, 2 65mm
    int hal;            // 0 off, 1 on, 2 on + softness
};

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
    fprintf(stderr, "unknown param %s\n", n.c_str());
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        int W = 3840, H = 2160, N = 30;
        bool dump = false;
        std::vector<char*> pos;
        for (int i = 1; i < argc; ++i) { if (!std::strcmp(argv[i], "--dump")) dump = true; else pos.push_back(argv[i]); }
        if (pos.size() >= 2) { W = atoi(pos[0]); H = atoi(pos[1]); }
        if (pos.size() >= 3) N = atoi(pos[2]);
        const PluginDef& def = kPlugin_drt;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        printf("GPU %s  %dx%d  %d frames/scenario\n", dev.name.UTF8String, W, H, N);

        // A log-like test picture: ramps, a skin-ish patch, saturated colours,
        // highlights above 1 for the halation, and noise so nothing is flat.
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
        id<MTLBuffer> src = [dev newBufferWithBytes:img.data() length:img.size() * 4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> dst = [dev newBufferWithLength:img.size() * 4 options:MTLResourceStorageModeShared];

        static const Scenario sc[] = {
            {"default", "", 0, 0},
            {"look 250D/2383", "look_preset=1", 0, 0},
            {"look intensity 0.5", "look_preset=1 look_intensity=0.5", 0, 0},
            {"skin sat 0.3", "trim_skin_sat=0.3", 0, 0},
            {"skin sat + edge 0.5", "trim_skin_sat=0.3 skin_medge=0.5", 0, 0},
            {"skin all + line", "trim_skin_sat=0.3 trim_skin=0.5 skin_mid=0.2 skin_medge=0.5", 0, 0},
            {"trims typical", "trim_con=0.2 trim_sh=0.2 trim_hp=0.3 trim_br=0.2 col_dens=0.3 col_weight=0.3", 0, 0},
            {"grain 35mm", "", 1, 0},
            {"grain 65mm", "", 2, 0},
            {"halation", "", 0, 1},
            {"halation + soft", "", 0, 2},
            {"grain + halation", "", 1, 1},
            {"everything", "look_preset=1 look_intensity=0.5 trim_skin_sat=0.3 skin_medge=0.5 trim_con=0.2", 1, 2},
        };
        for (const Scenario& S : sc) {
            std::vector<uint32_t> block(def.paramsSize / 4, 0u);
            for (int i = 0; i < def.nParams; ++i) {
                const ParamSpec& p = def.params[i];
                if (p.offset >= kPluginOnly) continue;
                if (p.kind == kParamFloat) { float v = (float)p.def; std::memcpy(&block[p.offset / 4], &v, 4); }
                else { int32_t v = (int32_t)std::lround(p.def); std::memcpy(&block[p.offset / 4], &v, 4); }
            }
            char buf[512];
            std::strncpy(buf, S.sets, sizeof(buf) - 1);
            buf[sizeof(buf) - 1] = 0;
            for (char* t = std::strtok(buf, " "); t; t = std::strtok(nullptr, " ")) {
                char* e = std::strchr(t, '=');
                if (!e) continue;
                *e = 0;
                setParam(def, block, t, atof(e + 1));
            }
            TextureSettings ts;
            ts.grainOn = S.grain != 0; ts.gauge = S.grain == 2 ? 0 : 1;
            ts.halOn = S.hal != 0; ts.halSoftness = S.hal == 2 ? 0.6f : 0.0f; ts.seed = 777;
            TexturePlan plan;
            if (ts.active()) texturePlan(ts, W, H, plan);
            MetalScratch* scr = metalScratchCreate();
            MetalJob j{};
            j.def = &def; j.params = block.data(); j.lut = nullptr; j.scratch = scr;
            j.commandQueue = (__bridge void*)q; j.srcBuffer = (__bridge void*)src; j.dstBuffer = (__bridge void*)dst;
            j.width = W; j.height = H; j.srcRowFloats = W * 4; j.dstRowFloats = W * 4; j.flipY = 1;
            j.texture = ts.active() ? &plan : nullptr;
            std::string err;
            for (int w = 0; w < 3; ++w) metalRender(j, err);   // warm-up (+ kernel compile)
            { id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
            // let a background (specialised) compile finish, then render once more
            [NSThread sleepForTimeInterval:getenv("BENCH_WAIT") ? atof(getenv("BENCH_WAIT")) : 1.5];
            metalRender(j, err);
            [NSThread sleepForTimeInterval:getenv("BENCH_WAIT") ? atof(getenv("BENCH_WAIT")) : 1.5];
            metalRender(j, err);
            { id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted]; }
            NSDate* t0 = [NSDate date];
            for (int f = 0; f < N; ++f) {
                if (!metalRender(j, err)) { printf("render failed: %s\n", err.c_str()); return 1; }
            }
            id<MTLCommandBuffer> cb = [q commandBuffer]; [cb commit]; [cb waitUntilCompleted];
            const double ms = -[t0 timeIntervalSinceNow] * 1000.0 / N;
            const float* o = (const float*)dst.contents;
            double sum = 0; for (size_t i = 0; i < img.size(); i += 7) sum += o[i];
            printf("  %-22s %7.2f ms/frame  (%5.1f fps)   checksum %.6f\n", S.name, ms, 1000.0 / ms, sum);
            if (dump) {
                std::string nm = S.name;
                for (auto& c : nm) if (c == ' ' || c == '/') c = '_';
                const char* dir = getenv("DUMPDIR") ? getenv("DUMPDIR") : "build";
                std::string fn = std::string(dir) + "/bench_" + nm + ".raw";
                FILE* f = fopen(fn.c_str(), "wb");
                if (f) { fwrite(o, 4, img.size(), f); fclose(f); }
            }
            metalScratchDestroy(scr);
        }
    }
    return 0;
}
