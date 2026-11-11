// =============================================================================
//  NODE_ONE OFX — Metal backend (macOS)
// -----------------------------------------------------------------------------
//  The DCTL Metal source generated for each effect is compiled once per GPU
//  with fast-math OFF (IEEE-754, same numbers as the CPU path), cached, and
//  dispatched on the command queue the host gives us. Nothing waits on the GPU:
//  the host orders the work on its own queue.
//  Compile problems are written to ~/Library/Logs/NodeOne/<effect>.log.
// =============================================================================
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <condition_variable>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "NodeOneLut.h"
#include "NodeOneMetal.h"
#include "NodeOneChain.h"
#include "NodeOnePlugin.h"
#include "lut_metal_src.h"
#include "NodeTexture.h"
#include "texture_metal_src.h"
#include "NodeDensity.h"
#include "density_metal_src.h"

#if !__has_feature(objc_arc)
#error "NodeOneMetal.mm must be compiled with -fobjc-arc"
#endif

namespace nodeone {
namespace {

struct KernelDims {
    int32_t width, height, rowFloatsSrc, rowFloatsDst, flipY, pad0, pad1, pad2;
};

struct Entry {
    id<MTLComputePipelineState> pso = nil;
    std::string error;
    bool compiling = false;
    bool done = false;
};

std::mutex gMutex;
std::condition_variable gCv;
std::map<std::string, Entry> gCache;

std::string cacheKey(id<MTLDevice> dev, const PluginDef* def)
{
    return std::to_string((unsigned long long)dev.registryID) + "|" + def->identifier;
}

void writeLog(const PluginDef* def, const std::string& text)
{
    @autoreleasepool {
        NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/NodeOne"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.log", def->identifier]];
        NSString* body = [NSString stringWithFormat:@"%@\n%s\n", [NSDate date], text.c_str()];
        [body writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

MTLCompileOptions* compileOptions()
{
    MTLCompileOptions* o = [MTLCompileOptions new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    o.fastMathEnabled = NO;
#pragma clang diagnostic pop
    return o;
}

void startCompile(id<MTLDevice> dev, const PluginDef* def)
{
    const std::string key = cacheKey(dev, def);
    {
        std::lock_guard<std::mutex> lock(gMutex);
        Entry& e = gCache[key];
        if (e.compiling || e.done) return;
        e.compiling = true;
    }
    NSString* src = [NSString stringWithUTF8String:def->metalSource];
    NSString* fnName = [NSString stringWithUTF8String:def->metalKernelName];
    [dev newLibraryWithSource:src
                      options:compileOptions()
            completionHandler:^(id<MTLLibrary> lib, NSError* err) {
              id<MTLComputePipelineState> pso = nil;
              std::string msg;
              if (lib) {
                  id<MTLFunction> fn = [lib newFunctionWithName:fnName];
                  if (fn) {
                      NSError* perr = nil;
                      pso = [dev newComputePipelineStateWithFunction:fn error:&perr];
                      if (!pso) msg = perr ? perr.localizedDescription.UTF8String : "pipeline creation failed";
                  } else {
                      msg = "kernel entry point not found";
                  }
              } else {
                  msg = err ? err.localizedDescription.UTF8String : "Metal compile failed";
              }
              if (!msg.empty()) writeLog(def, msg);
              {
                  std::lock_guard<std::mutex> lock(gMutex);
                  Entry& e = gCache[key];
                  e.pso = pso;
                  e.error = msg;
                  e.done = true;
                  e.compiling = false;
              }
              gCv.notify_all();
            }];
}

id<MTLComputePipelineState> pipeline(id<MTLDevice> dev, const PluginDef* def, std::string& error)
{
    startCompile(dev, def);
    const std::string key = cacheKey(dev, def);
    std::unique_lock<std::mutex> lock(gMutex);
    gCv.wait(lock, [&] { return gCache[key].done; });
    Entry& e = gCache[key];
    error = e.error;
    return e.pso;
}

// =============================================================================
//  SPECIALISED KERNELS
// -----------------------------------------------------------------------------
//  The generic kernel reads every setting from the parameter block, so it has
//  to carry every branch of the DCTL at once: every look, every tonescale,
//  every display, every trim. That costs registers, the GPU runs it with few
//  threads in flight, and it is slow (57 ms per UHD frame on an M2 Pro with
//  the default settings).
//
//  A specialised kernel is the same source compiled with some settings fixed
//  (see NODEONE_SPEC_ in tools/dctl2ofx.py): every menu and checkbox, and any
//  slider sitting exactly at +0 or 1. The compiler removes what cannot run.
//  Same DCTL, same arithmetic, fast-math still off - and several times faster.
//
//  Variants are compiled in the background the first time a combination is
//  seen and kept. Until a variant is ready the generic kernel renders the
//  frame, so changing a menu never stalls playback.
// =============================================================================
struct SpecEntry {
    id<MTLComputePipelineState> pso = nil;
    bool compiling = false;
    bool failed = false;
    uint64_t lastUse = 0;
};
std::mutex gSpecMutex;
std::map<std::string, SpecEntry> gSpec;
uint64_t gSpecClock = 0;
int gSpecInFlight = 0;
const size_t kSpecMax = 64;        // variants kept per process (a few KB each)
const int kSpecMaxInFlight = 4;    // compiles running at once

// Key + macros for the settings in this parameter block. A float is fixed only
// when its bits are exactly +0.0f or 1.0f, so the constant is the value itself.
std::string specKey(id<MTLDevice> dev, const PluginDef* def, const void* params, NSMutableDictionary* macros,
                    int skinPrepass, int skinFeat)
{
    std::string key = std::to_string((unsigned long long)dev.registryID) + "|" + def->identifier;
    // Skin mask pre-pass (see skinPasses): the pre-pass kernel for one look
    // pass, or the main kernel that reads what the pre-passes wrote.
    if (skinPrepass >= 0) {
        key += "|SKINPRE=" + std::to_string(skinPrepass);
        if (macros) macros[@"NODEONE_SKIN_PREPASS"] = [NSString stringWithFormat:@"%d", skinPrepass];
    }
    if (skinFeat > 0) {
        key += "|SKINFEAT=" + std::to_string(skinFeat);
        if (macros) macros[@"NODEONE_SKIN_FEAT"] = [NSString stringWithFormat:@"%d", skinFeat];
    }
    const uint8_t* b = static_cast<const uint8_t*>(params);
    for (int i = 0; i < def->nParams; ++i) {
        const ParamSpec& p = def->params[i];
        if (p.offset >= kPluginOnly) continue;      // plugin-only / synthetic: not in the block
        uint32_t bits = 0;
        std::memcpy(&bits, b + p.offset, 4);
        std::string val;
        if (p.kind == kParamFloat) {
            if (bits == 0x00000000u) val = "0.0f";
            else if (bits == 0x3F800000u) val = "1.0f";
            else continue;
        } else {
            val = "(" + std::to_string((int32_t)bits) + ")";
        }
        key += "|";
        key += p.name;
        key += "=";
        key += val;
        if (macros)
            macros[[NSString stringWithFormat:@"NODEONE_SPEC_%s", p.name]] = [NSString stringWithUTF8String:val.c_str()];
    }
    return key;
}

void specEvict()   // gSpecMutex held
{
    while (gSpec.size() > kSpecMax) {
        auto victim = gSpec.end();
        for (auto it = gSpec.begin(); it != gSpec.end(); ++it)
            if (!it->second.compiling && (victim == gSpec.end() || it->second.lastUse < victim->second.lastUse))
                victim = it;
        if (victim == gSpec.end()) return;
        gSpec.erase(victim);
    }
}

// Non-blocking: the specialised pipeline when it is ready, nil otherwise (and
// its compile is started if it was not already).
id<MTLComputePipelineState> specializedPipeline(id<MTLDevice> dev, const PluginDef* def, const void* params,
                                                int skinPrepass = -1, int skinFeat = 0)
{
    if (!dev || !def || !params || !def->metalSource) return nil;
    const std::string key = specKey(dev, def, params, nil, skinPrepass, skinFeat);
    {
        std::lock_guard<std::mutex> lock(gSpecMutex);
        auto it = gSpec.find(key);
        if (it != gSpec.end()) {
            it->second.lastUse = ++gSpecClock;
            return it->second.pso;      // nil while compiling or if it failed
        }
        if (gSpecInFlight >= kSpecMaxInFlight) return nil;   // try again next frame
        SpecEntry& e = gSpec[key];
        e.compiling = true;
        e.lastUse = ++gSpecClock;
        ++gSpecInFlight;
        specEvict();
    }
    NSMutableDictionary* macros = [NSMutableDictionary dictionary];
    specKey(dev, def, params, macros, skinPrepass, skinFeat);
    MTLCompileOptions* o = compileOptions();
    o.preprocessorMacros = macros;
    NSString* src = [NSString stringWithUTF8String:def->metalSource];
    NSString* fnName = [NSString stringWithUTF8String:def->metalKernelName];
    [dev newLibraryWithSource:src
                      options:o
            completionHandler:^(id<MTLLibrary> lib, NSError* err) {
              id<MTLComputePipelineState> pso = nil;
              std::string msg;
              if (lib) {
                  id<MTLFunction> fn = [lib newFunctionWithName:fnName];
                  if (fn) {
                      NSError* perr = nil;
                      pso = [dev newComputePipelineStateWithFunction:fn error:&perr];
                      if (!pso) msg = perr ? perr.localizedDescription.UTF8String : "pipeline creation failed";
                  } else {
                      msg = "kernel entry point not found";
                  }
              } else {
                  msg = err ? err.localizedDescription.UTF8String : "Metal compile failed";
              }
              if (!msg.empty()) writeLog(def, "specialised kernel: " + msg);
              std::lock_guard<std::mutex> lock(gSpecMutex);
              --gSpecInFlight;
              SpecEntry& e = gSpec[key];
              e.pso = pso;
              e.failed = (pso == nil);
              e.compiling = false;
            }];
    return nil;
}

// SKIN MASK PRE-PASS. The skin mask averages 17 (33 with Mask Edge Softness)
// samples around each pixel, and each sample used to redo the whole scene
// colour path of its pixel (log curve, white balance, gamut, look space, skin
// windows). That part depends only on the sampled pixel: a pre-pass of the same
// kernel (NODEONE_SKIN_PREPASS) writes it once per pixel, and the main kernel
// (NODEONE_SKIN_FEAT) reads it - the same skin_tap() of the DCTL, computed once
// instead of 17 to 33 times.
// Returns how many look passes need the pre-pass (0: skin mask not in use, or
// not this effect; 2 when Look Intensity renders the picture twice). This
// mirrors the DCTL's own conditions; if it ever disagreed, the result would
// only be slower, never different: the main kernel computes any pass it was
// not given.
float specParamF(const PluginDef* def, const void* params, const char* name, bool& found)
{
    for (int i = 0; i < def->nParams; ++i)
        if (std::strcmp(def->params[i].name, name) == 0 && def->params[i].offset < kPluginOnly) {
            found = true;
            const uint8_t* b = static_cast<const uint8_t*>(params) + def->params[i].offset;
            if (def->params[i].kind == kParamFloat) { float v; std::memcpy(&v, b, 4); return v; }
            int32_t v; std::memcpy(&v, b, 4); return (float)v;
        }
    found = false;
    return 0.0f;
}
int skinPasses(const PluginDef* def, const void* params)
{
    bool ok = true, f = false;
    auto P = [&](const char* n) { const float v = specParamF(def, params, n, f); ok = ok && f; return v; };
    const float sat = P("trim_skin_sat"), line = P("trim_skin"), colByp = P("skin_col_bypass");
    const float hi = P("skin_hi"), mid = P("skin_mid"), sh = P("skin_sh"), lightByp = P("skin_light_bypass");
    const float zones = P("skin_zones"), lookByp = P("look_bypass"), lookI = P("look_intensity");
    if (!ok) return 0;
    const bool active = ((sat != 0.0f || line > 0.0f) && colByp == 0.0f) ||
                        ((hi != 0.0f || mid != 0.0f || sh != 0.0f) && lightByp == 0.0f) || zones == 1.0f;
    if (!active) return 0;
    const float t = lookByp != 0.0f ? 0.0f : std::fmin(std::fmax(lookI, 0.0f), 1.0f);
    return (t > 0.0f && t < 1.0f) ? 2 : 1;
}

} // namespace

// =============================================================================
//  Per-instance GPU scratch: the buffers the LUT stage and the chain render
//  through, plus the uploaded LUT table. Kept alive between frames.
// =============================================================================
struct MetalScratch {
    id<MTLBuffer> buf[2] = {nil, nil};
    NSUInteger bytes = 0;
    id<MTLBuffer> lutBuf = nil;      // the uploaded LUT table
    const Lut3D* lutHeld = nullptr;  // which LUT it holds, to avoid re-uploading
    id<MTLBuffer> input = nil;       // copy of the source for an in-place spatial render
    NSUInteger inputBytes = 0;
    // Texture stage (grain + halation): its output, the halation source, its
    // half-resolution copy, the six-term blur pass, the blurred source, and
    // the horizontal grain pass. Grown as needed, kept between frames.
    id<MTLBuffer> tex[6] = {nil, nil, nil, nil, nil, nil};
    NSUInteger texBytes[6] = {0, 0, 0, 0, 0, 0};
    // kernel tables of the texture stage (halation, halo softness, grain)
    id<MTLBuffer> tbl[3] = {nil, nil, nil};
    std::vector<float> tblData[3];
    // Density Pro: key, its blur ping-pong, the stage output
    id<MTLBuffer> dens[4] = {nil, nil, nil, nil};
    NSUInteger densBytes[4] = {0, 0, 0, 0};
    // skin mask pre-pass: one W x H x 4 plane per look pass
    id<MTLBuffer> skin = nil;
    NSUInteger skinBytes = 0;
};

MetalScratch* metalScratchCreate() { return new MetalScratch(); }

void metalScratchDestroy(MetalScratch* s)
{
    if (!s) return;
    @autoreleasepool {
        s->buf[0] = nil;
        s->buf[1] = nil;
        s->lutBuf = nil;
        s->input = nil;
        for (int i = 0; i < 6; ++i) s->tex[i] = nil;
        for (int i = 0; i < 3; ++i) s->tbl[i] = nil;
        for (int i = 0; i < 4; ++i) s->dens[i] = nil;
        s->skin = nil;
    }
    delete s;
}

namespace {

// ---- SONDE : sous-echantillonnage ponctuel vers un tampon lisible CPU --------
// Le noyau est minuscule et fixe, donc compile une fois et garde. S'il echoue,
// on ne sonde pas - la mesure rendra simplement "rien d'exploitable" au lieu de
// tomber.
// Encodes one stage: input buffer -> output buffer, through that stage's kernel.
void encodeStage(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> pso, const void* params, size_t paramsSize,
                 id<MTLBuffer> in, int inRowFloats, id<MTLBuffer> out, int outRowFloats, int W, int H, int flipY,
                 id<MTLBuffer> aux = nil, NSUInteger outOffset = 0)
{
    KernelDims d = {W, H, inRowFloats, outRowFloats, flipY, 0, 0, 0};
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBytes:params length:paramsSize atIndex:0];
    [enc setBuffer:in offset:0 atIndex:1];
    [enc setBuffer:out offset:outOffset atIndex:2];
    [enc setBytes:&d length:sizeof(d) atIndex:3];
    [enc setBuffer:(aux ? aux : in) offset:0 atIndex:4];   // skin pre-pass values (unused otherwise)
    const NSUInteger tw = pso.threadExecutionWidth;
    const NSUInteger th = MAX((NSUInteger)1, pso.maxTotalThreadsPerThreadgroup / tw);
    const MTLSize tg = MTLSizeMake(tw, MIN(th, (NSUInteger)8), 1);
    const MTLSize grid = MTLSizeMake(((NSUInteger)W + tg.width - 1) / tg.width,
                                     ((NSUInteger)H + tg.height - 1) / tg.height, 1);
    [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
}

struct LutKernelParams {
    int32_t width, height, rowFloatsSrc, rowFloatsDst;
    int32_t size, pad0, pad1, pad2;
    float dmin0, dmin1, dmin2, dpad0;
    float dmax0, dmax1, dmax2, dpad1;
};

// The LUT kernel is the same for every effect, so one pipeline per device.
id<MTLComputePipelineState> lutPipeline(id<MTLDevice> dev, std::string& error)
{
    static std::mutex m;
    static std::map<unsigned long long, id<MTLComputePipelineState>> cache;
    static std::map<unsigned long long, std::string> errors;
    const unsigned long long key = dev.registryID;
    {
        std::lock_guard<std::mutex> lock(m);
        auto it = cache.find(key);
        if (it != cache.end()) return it->second;
        auto e = errors.find(key);
        if (e != errors.end()) { error = e->second; return nil; }
    }
    NSError* err = nil;
    MTLCompileOptions* o = [MTLCompileOptions new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    o.fastMathEnabled = NO;
#pragma clang diagnostic pop
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kLutMetalSource]
                                           options:o
                                             error:&err];
    id<MTLComputePipelineState> pso = nil;
    std::string msg;
    if (lib) {
        id<MTLFunction> fn = [lib newFunctionWithName:@"node_one_main"];
        if (fn) {
            NSError* perr = nil;
            pso = [dev newComputePipelineStateWithFunction:fn error:&perr];
            if (!pso) msg = perr ? perr.localizedDescription.UTF8String : "LUT pipeline creation failed";
        } else {
            msg = "LUT kernel entry point not found";
        }
    } else {
        msg = err ? err.localizedDescription.UTF8String : "LUT kernel compile failed";
    }
    std::lock_guard<std::mutex> lock(m);
    if (pso) cache[key] = pso; else { errors[key] = msg; error = msg; }
    return pso;
}

// Uploads the table once and keeps it on the instance.
id<MTLBuffer> lutBuffer(id<MTLDevice> dev, MetalScratch* s, const Lut3D* lut)
{
    if (s->lutBuf && s->lutHeld == lut) return s->lutBuf;
    id<MTLBuffer> b = [dev newBufferWithBytes:lut->data.data()
                                       length:lut->data.size() * sizeof(float)
                                      options:MTLResourceStorageModeShared];
    if (!b) return nil;
    s->lutBuf = b;
    s->lutHeld = lut;
    return b;
}

void encodeLut(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> pso, const Lut3D& lut, id<MTLBuffer> table,
               id<MTLBuffer> in, int inRowFloats, id<MTLBuffer> out, int outRowFloats, int W, int H)
{
    LutKernelParams p = {W, H, inRowFloats, outRowFloats, lut.size, 0, 0, 0,
                         lut.domainMin[0], lut.domainMin[1], lut.domainMin[2], 0.0f,
                         lut.domainMax[0], lut.domainMax[1], lut.domainMax[2], 0.0f};
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBytes:&p length:sizeof(p) atIndex:0];
    [enc setBuffer:in offset:0 atIndex:1];
    [enc setBuffer:out offset:0 atIndex:2];
    [enc setBuffer:table offset:0 atIndex:3];
    const NSUInteger tw = pso.threadExecutionWidth;
    const NSUInteger th = MAX((NSUInteger)1, pso.maxTotalThreadsPerThreadgroup / tw);
    const MTLSize tg = MTLSizeMake(tw, MIN(th, (NSUInteger)8), 1);
    const MTLSize grid = MTLSizeMake(((NSUInteger)W + tg.width - 1) / tg.width,
                                     ((NSUInteger)H + tg.height - 1) / tg.height, 1);
    [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
}

void blitCopy(id<MTLCommandBuffer> cb, id<MTLBuffer> src, int srcRowFloats, id<MTLBuffer> dst, int dstRowFloats,
              int W, int H)
{
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (srcRowFloats == dstRowFloats) {
        [blit copyFromBuffer:src sourceOffset:0 toBuffer:dst destinationOffset:0
                        size:(NSUInteger)srcRowFloats * H * sizeof(float)];
    } else {
        const NSUInteger rowBytes = (NSUInteger)W * 4 * sizeof(float);
        for (int r = 0; r < H; ++r)
            [blit copyFromBuffer:src sourceOffset:(NSUInteger)r * srcRowFloats * sizeof(float)
                        toBuffer:dst destinationOffset:(NSUInteger)r * dstRowFloats * sizeof(float)
                            size:rowBytes];
    }
    [blit endEncoding];
}

// =============================================================================
//  Texture stage (grain + halation) on the GPU: the passes of textureCPU().
// =============================================================================
enum { TX_SRC, TX_DOWN, TX_HH, TX_HV, TX_SH, TX_SV, TX_GH, TX_FINAL, TX_N };

struct TexturePsos { id<MTLComputePipelineState> p[TX_N]; };

bool texturePipelines(id<MTLDevice> dev, TexturePsos& out, std::string& error)
{
    static std::mutex m;
    static std::map<unsigned long long, TexturePsos> cache;
    static std::map<unsigned long long, std::string> errors;
    const unsigned long long key = dev.registryID;
    std::lock_guard<std::mutex> lock(m);
    auto it = cache.find(key);
    if (it != cache.end()) { out = it->second; return true; }
    auto e = errors.find(key);
    if (e != errors.end()) { error = e->second; return false; }
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kTextureMetalSource]
                                           options:compileOptions()
                                             error:&err];
    std::string msg;
    TexturePsos ps;
    static const char* const names[TX_N] = {"tx_src", "tx_down", "tx_hh", "tx_hv", "tx_sh", "tx_sv", "tx_gh", "tx_final"};
    if (!lib) msg = err ? err.localizedDescription.UTF8String : "texture kernels compile failed";
    for (int i = 0; i < TX_N && msg.empty(); ++i) {
        id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
        if (!fn) { msg = std::string("texture kernel ") + names[i] + " not found"; break; }
        NSError* perr = nil;
        ps.p[i] = [dev newComputePipelineStateWithFunction:fn error:&perr];
        if (!ps.p[i]) msg = perr ? perr.localizedDescription.UTF8String : "texture pipeline creation failed";
    }
    if (!msg.empty()) { errors[key] = msg; error = msg; return false; }
    cache[key] = ps;
    out = ps;
    return true;
}

id<MTLBuffer> texBuffer(id<MTLDevice> dev, MetalScratch* s, int i, NSUInteger bytes)
{
    bytes = MAX(bytes, (NSUInteger)16);
    if (s->texBytes[i] < bytes || !s->tex[i]) {
        s->tex[i] = [dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        s->texBytes[i] = s->tex[i] ? bytes : 0;
    }
    return s->tex[i];
}

void dispatch2D(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso, int w, int h)
{
    const NSUInteger tw = pso.threadExecutionWidth;
    const NSUInteger th = MAX((NSUInteger)1, pso.maxTotalThreadsPerThreadgroup / tw);
    const MTLSize tg = MTLSizeMake(tw, MIN(th, (NSUInteger)8), 1);
    const MTLSize grid = MTLSizeMake(((NSUInteger)w + tg.width - 1) / tg.width, ((NSUInteger)h + tg.height - 1) / tg.height, 1);
    [enc dispatchThreadgroups:grid threadsPerThreadgroup:tg];
}

// small tables go inline, larger ones in a buffer kept on the instance and
// re-uploaded only when the table changes (not on every frame).
void setTable(id<MTLComputeCommandEncoder> enc, id<MTLDevice> dev, MetalScratch* s, int slot,
              const std::vector<float>& v, NSUInteger index)
{
    const NSUInteger bytes = MAX((NSUInteger)v.size() * sizeof(float), (NSUInteger)4);
    static const float zero = 0.0f;
    const void* data = v.empty() ? (const void*)&zero : (const void*)v.data();
    if (bytes <= 4096) { [enc setBytes:data length:bytes atIndex:index]; return; }
    if (!s->tbl[slot] || s->tblData[slot] != v) {
        s->tbl[slot] = [dev newBufferWithBytes:data length:bytes options:MTLResourceStorageModeShared];
        s->tblData[slot] = v;
    }
    [enc setBuffer:s->tbl[slot] offset:0 atIndex:index];
}

// Encodes the texture stage: src -> returned buffer (W x 4 floats per row).
// nil when a buffer could not be allocated.
id<MTLBuffer> encodeTexture(id<MTLCommandBuffer> cb, id<MTLDevice> dev, const TexturePsos& ps, const TexturePlan& plan,
                            id<MTLBuffer> src, int srcRowFloats, MetalScratch* s)
{
    TexArgs A = plan.a;
    A.srcRow = srcRowFloats;
    A.dstRow = A.W * 4;
    const NSUInteger W = (NSUInteger)A.W, H = (NSUInteger)A.H;
    id<MTLBuffer> out = texBuffer(dev, s, 0, W * H * 4 * sizeof(float));
    id<MTLBuffer> S = src, Sd = src, tmp6 = src, Bg = src, T = src;
    if (A.halOn) {
        S = texBuffer(dev, s, 1, W * H * sizeof(float));
        Sd = A.halfRes ? texBuffer(dev, s, 2, (NSUInteger)A.W2 * A.H2 * sizeof(float)) : S;
        tmp6 = texBuffer(dev, s, 3, (NSUInteger)6 * A.W2 * A.H2 * sizeof(float));
        Bg = texBuffer(dev, s, 4, (NSUInteger)A.W2 * A.H2 * sizeof(float));
    }
    if (A.grOn) T = texBuffer(dev, s, 5, (NSUInteger)3 * W * (H + 2 * A.grR) * sizeof(float));
    if (!out || !S || !Sd || !tmp6 || !Bg || !T) return nil;

    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    if (A.halOn) {
        [enc setComputePipelineState:ps.p[TX_SRC]];
        [enc setBytes:&A length:sizeof(A) atIndex:0];
        [enc setBuffer:src offset:0 atIndex:1];
        [enc setBuffer:S offset:0 atIndex:2];
        dispatch2D(enc, ps.p[TX_SRC], A.W, A.H);
        if (A.halfRes) {
            [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
            [enc setComputePipelineState:ps.p[TX_DOWN]];
            [enc setBytes:&A length:sizeof(A) atIndex:0];
            [enc setBuffer:S offset:0 atIndex:1];
            [enc setBuffer:Sd offset:0 atIndex:2];
            dispatch2D(enc, ps.p[TX_DOWN], A.W2, A.H2);
        }
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
        [enc setComputePipelineState:ps.p[TX_HH]];
        [enc setBytes:&A length:sizeof(A) atIndex:0];
        [enc setBuffer:Sd offset:0 atIndex:1];
        setTable(enc, dev, s, 0, plan.halK, 2);
        [enc setBuffer:tmp6 offset:0 atIndex:3];
        dispatch2D(enc, ps.p[TX_HH], A.W2, A.H2);
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
        [enc setComputePipelineState:ps.p[TX_HV]];
        [enc setBytes:&A length:sizeof(A) atIndex:0];
        [enc setBuffer:tmp6 offset:0 atIndex:1];
        setTable(enc, dev, s, 0, plan.halK, 2);
        [enc setBuffer:Bg offset:0 atIndex:3];
        [enc setBuffer:Sd offset:0 atIndex:4];
        dispatch2D(enc, ps.p[TX_HV], A.W2, A.H2);
        if (A.halSoftR > 0) {   // tmp6's first plane is free again
            [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
            [enc setComputePipelineState:ps.p[TX_SH]];
            [enc setBytes:&A length:sizeof(A) atIndex:0];
            [enc setBuffer:Bg offset:0 atIndex:1];
            setTable(enc, dev, s, 1, plan.halSoftK, 2);
            [enc setBuffer:tmp6 offset:0 atIndex:3];
            dispatch2D(enc, ps.p[TX_SH], A.W2, A.H2);
            [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
            [enc setComputePipelineState:ps.p[TX_SV]];
            [enc setBytes:&A length:sizeof(A) atIndex:0];
            [enc setBuffer:tmp6 offset:0 atIndex:1];
            setTable(enc, dev, s, 1, plan.halSoftK, 2);
            [enc setBuffer:Bg offset:0 atIndex:3];
            dispatch2D(enc, ps.p[TX_SV], A.W2, A.H2);
        }
    }
    if (A.grOn) {
        // One threadgroup = a run of TW pixels of one row; its noise is drawn
        // once into threadgroup memory (see tx_gh).
        const NSUInteger TW = MIN((NSUInteger)256, ps.p[TX_GH].maxTotalThreadsPerThreadgroup);
        const NSUInteger tgBytes = ((NSUInteger)3 * (TW + 2 * (NSUInteger)A.grR) * sizeof(float) + 15) & ~(NSUInteger)15;
        [enc setComputePipelineState:ps.p[TX_GH]];
        [enc setBytes:&A length:sizeof(A) atIndex:0];
        setTable(enc, dev, s, 2, plan.grK, 1);
        [enc setBuffer:T offset:0 atIndex:2];
        [enc setThreadgroupMemoryLength:tgBytes atIndex:0];
        [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)A.W + TW - 1) / TW, (NSUInteger)(A.H + 2 * A.grR), 1)
            threadsPerThreadgroup:MTLSizeMake(TW, 1, 1)];
    }
    [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [enc setComputePipelineState:ps.p[TX_FINAL]];
    [enc setBytes:&A length:sizeof(A) atIndex:0];
    [enc setBuffer:src offset:0 atIndex:1];
    [enc setBuffer:out offset:0 atIndex:2];
    [enc setBuffer:S offset:0 atIndex:3];
    [enc setBuffer:Bg offset:0 atIndex:4];
    setTable(enc, dev, s, 2, plan.grK, 5);
    [enc setBuffer:T offset:0 atIndex:6];
    dispatch2D(enc, ps.p[TX_FINAL], A.W, A.H);
    [enc endEncoding];
    return out;
}

// =============================================================================
//  Density Pro stage on the GPU: the passes of densityCPU().
// =============================================================================
enum { DP_KEY, DP_BOXH, DP_BOXV, DP_GRID, DP_APPLY, DP_N };
struct DensityPsos { id<MTLComputePipelineState> p[DP_N]; };

bool densityPipelines(id<MTLDevice> dev, DensityPsos& out, std::string& error)
{
    static std::mutex m;
    static std::map<unsigned long long, DensityPsos> cache;
    static std::map<unsigned long long, std::string> errors;
    const unsigned long long key = dev.registryID;
    std::lock_guard<std::mutex> lock(m);
    auto it = cache.find(key);
    if (it != cache.end()) { out = it->second; return true; }
    auto e = errors.find(key);
    if (e != errors.end()) { error = e->second; return false; }
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kDensityMetalSource]
                                           options:compileOptions()
                                             error:&err];
    std::string msg;
    DensityPsos ps;
    static const char* const names[DP_N] = {"dp_key", "dp_boxh", "dp_boxv", "dp_grid", "dp_apply"};
    if (!lib) msg = err ? err.localizedDescription.UTF8String : "density kernels compile failed";
    for (int i = 0; i < DP_N && msg.empty(); ++i) {
        id<MTLFunction> fn = [lib newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
        if (!fn) { msg = std::string("density kernel ") + names[i] + " not found"; break; }
        NSError* perr = nil;
        ps.p[i] = [dev newComputePipelineStateWithFunction:fn error:&perr];
        if (!ps.p[i]) msg = perr ? perr.localizedDescription.UTF8String : "density pipeline creation failed";
    }
    if (!msg.empty()) { errors[key] = msg; error = msg; return false; }
    cache[key] = ps;
    out = ps;
    return true;
}

void dispatch1D(id<MTLComputeCommandEncoder> enc, id<MTLComputePipelineState> pso, int n)
{
    const NSUInteger tw = MIN((NSUInteger)64, pso.maxTotalThreadsPerThreadgroup);
    [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)n + tw - 1) / tw, 1, 1) threadsPerThreadgroup:MTLSizeMake(tw, 1, 1)];
}

id<MTLBuffer> densBuffer(id<MTLDevice> dev, MetalScratch* s, int i, NSUInteger bytes)
{
    bytes = MAX(bytes, (NSUInteger)16);
    if (s->densBytes[i] < bytes || !s->dens[i]) {
        s->dens[i] = [dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        s->densBytes[i] = s->dens[i] ? bytes : 0;
    }
    return s->dens[i];
}

// Encodes Density Pro: src -> returned buffer (W x 4 floats per row). nil when
// a buffer could not be allocated.
id<MTLBuffer> encodeDensity(id<MTLCommandBuffer> cb, id<MTLDevice> dev, const DensityPsos& ps, const DensityPlan& plan,
                            id<MTLBuffer> src, int srcRowFloats, MetalScratch* s)
{
    DensArgs A = plan.a;
    A.srcRow = srcRowFloats;
    A.dstRow = A.W * 4;
    const NSUInteger W = (NSUInteger)A.W, H = (NSUInteger)A.H;
    id<MTLBuffer> K = densBuffer(dev, s, 0, W * H * 3 * sizeof(float));
    id<MTLBuffer> T = A.blurR > 0 ? densBuffer(dev, s, 1, W * H * 3 * sizeof(float)) : K;
    id<MTLBuffer> out = densBuffer(dev, s, 2, W * H * 4 * sizeof(float));
    const int Wl = (A.W - 1) / 2 + 2, Hl = (A.H - 1) / 2 + 2;
    id<MTLBuffer> G = densBuffer(dev, s, 3, (NSUInteger)Wl * Hl * sizeof(float));
    if (!K || !T || !out || !G) return nil;
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:ps.p[DP_KEY]];
    [enc setBytes:&A length:sizeof(A) atIndex:0];
    [enc setBuffer:src offset:0 atIndex:1];
    [enc setBuffer:K offset:0 atIndex:2];
    dispatch2D(enc, ps.p[DP_KEY], A.W, A.H);
    for (int pass = 0; A.blurR > 0 && pass < 3; ++pass) {
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
        {   // a threadgroup = a run of TW pixels of one row, read once into threadgroup memory
            const NSUInteger TW = MIN((NSUInteger)256, ps.p[DP_BOXH].maxTotalThreadsPerThreadgroup);
            const NSUInteger tg = ((NSUInteger)3 * (TW + 2 * (NSUInteger)A.blurR) * sizeof(float) + 15) & ~(NSUInteger)15;
            [enc setComputePipelineState:ps.p[DP_BOXH]];
            [enc setBytes:&A length:sizeof(A) atIndex:0];
            [enc setBuffer:K offset:0 atIndex:1];
            [enc setBuffer:T offset:0 atIndex:2];
            [enc setThreadgroupMemoryLength:tg atIndex:0];
            [enc dispatchThreadgroups:MTLSizeMake(((NSUInteger)A.W + TW - 1) / TW, (NSUInteger)A.H, 1)
                threadsPerThreadgroup:MTLSizeMake(TW, 1, 1)];
        }
        [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
        [enc setComputePipelineState:ps.p[DP_BOXV]];
        [enc setBytes:&A length:sizeof(A) atIndex:0];
        [enc setBuffer:T offset:0 atIndex:1];
        [enc setBuffer:K offset:0 atIndex:2];
        dispatch2D(enc, ps.p[DP_BOXV], A.W * 3, (A.H + 63) / 64);   // one thread per 64-row run of a float column
    }
    [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [enc setComputePipelineState:ps.p[DP_GRID]];
    [enc setBytes:&A length:sizeof(A) atIndex:0];
    [enc setBuffer:K offset:0 atIndex:1];
    [enc setBuffer:G offset:0 atIndex:2];
    dispatch2D(enc, ps.p[DP_GRID], Wl, Hl);
    [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [enc setComputePipelineState:ps.p[DP_APPLY]];
    [enc setBytes:&A length:sizeof(A) atIndex:0];
    [enc setBuffer:src offset:0 atIndex:1];
    [enc setBuffer:out offset:0 atIndex:2];
    [enc setBuffer:K offset:0 atIndex:3];
    [enc setBuffer:G offset:0 atIndex:4];
    dispatch2D(enc, ps.p[DP_APPLY], A.W, A.H);
    [enc endEncoding];
    return out;
}

// CPU render of the whole effect (texture stage included) on shared memory.
void cpuFallback(const MetalJob& j, const float* src, float* dst)
{
    std::vector<float> tex, den;
    const float* in = src;
    ptrdiff_t inRow = j.srcRowFloats;
    if (j.density) {
        den.resize((size_t)j.width * 4 * j.height);
        densityCPU(*j.density, src, j.srcRowFloats, den.data(), (ptrdiff_t)j.width * 4);
        in = den.data();
        inRow = (ptrdiff_t)j.width * 4;
    }
    if (j.texture) {
        tex.resize((size_t)j.width * 4 * j.height);
        textureCPU(*j.texture, in, inRow, tex.data(), (ptrdiff_t)j.width * 4);
        in = tex.data();
        inRow = (ptrdiff_t)j.width * 4;
    }
    if (j.lut) {
        std::vector<float> tmp((size_t)j.width * 4 * j.height);
        cpuRender(*j.def, j.params, in, inRow, tmp.data(), (ptrdiff_t)j.width * 4, j.width, j.height, 0, j.height, j.flipY);
        lutApplyCPUThreaded(*j.lut, tmp.data(), (ptrdiff_t)j.width * 4, dst, j.dstRowFloats, j.width, j.height);
        return;
    }
    cpuRender(*j.def, j.params, in, inRow, dst, j.dstRowFloats, j.width, j.height, 0, j.height, j.flipY);
}

} // namespace

void metalPrewarm(const PluginDef& def, const void* params)
{
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return;
        startCompile(dev, &def);
        // and the variant for the settings the instance opens with
        if (params) specializedPipeline(dev, &def, params);
    }
}

bool metalRender(const MetalJob& j, std::string& error)
{
    @autoreleasepool {
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)j.commandQueue;
        id<MTLBuffer> src = (__bridge id<MTLBuffer>)j.srcBuffer;
        id<MTLBuffer> dst = (__bridge id<MTLBuffer>)j.dstBuffer;
        if (!queue || !src || !dst) {
            error = "missing Metal queue or image buffer";
            return false;
        }
        id<MTLDevice> dev = queue.device;
        std::string perr;
        // The specialised kernel when it is ready; the generic one otherwise
        // (waited for only if neither exists yet - the very first frame).
        id<MTLComputePipelineState> pso = specializedPipeline(dev, j.def, j.params);
        if (!pso) pso = pipeline(dev, j.def, perr);

        if (!pso) {
            // Kernel unavailable: run the CPU path on shared memory if possible.
            if (src.storageMode == MTLStorageModeShared && dst.storageMode == MTLStorageModeShared) {
                id<MTLCommandBuffer> sync = [queue commandBuffer];
                [sync commit];
                [sync waitUntilCompleted];
                cpuFallback(j, static_cast<const float*>(src.contents), static_cast<float*>(dst.contents));
                return true;
            }
            error = "Metal kernel unavailable (" + perr + "). See ~/Library/Logs/NodeOne/";
            return false;
        }

        // A LUT stage needs its own kernel and a buffer between the two passes.
        id<MTLComputePipelineState> lutPso = nil;
        id<MTLBuffer> lutTable = nil;
        if (j.lut) {
            std::string lerr;
            lutPso = lutPipeline(dev, lerr);
            const NSUInteger need = (NSUInteger)j.width * 4 * j.height * sizeof(float);
            if (lutPso && j.scratch) {
                if (j.scratch->bytes < need) {
                    j.scratch->buf[0] = [dev newBufferWithLength:need options:MTLResourceStorageModePrivate];
                    j.scratch->buf[1] = [dev newBufferWithLength:need options:MTLResourceStorageModePrivate];
                    j.scratch->bytes = (j.scratch->buf[0] && j.scratch->buf[1]) ? need : 0;
                }
                lutTable = lutBuffer(dev, j.scratch, j.lut);
            }
            if (!lutPso || !lutTable || !j.scratch || j.scratch->bytes < need) {
                // Fall back to the CPU for the whole effect rather than render
                // the log image, which would look badly wrong on screen.
                if (src.storageMode == MTLStorageModeShared && dst.storageMode == MTLStorageModeShared) {
                    id<MTLCommandBuffer> sync = [queue commandBuffer];
                    [sync commit];
                    [sync waitUntilCompleted];
                    cpuFallback(j, static_cast<const float*>(src.contents), static_cast<float*>(dst.contents));
                    return true;
                }
                error = "LUT stage unavailable on the GPU (" + lerr + "). See ~/Library/Logs/NodeOne/";
                return false;
            }
        }

        // The texture stage needs its own kernels; without them the whole
        // effect goes to the CPU rather than render without grain / halation.
        TexturePsos texPs;
        if (j.texture) {
            std::string terr;
            if (!j.scratch || !texturePipelines(dev, texPs, terr)) {
                if (src.storageMode == MTLStorageModeShared && dst.storageMode == MTLStorageModeShared) {
                    id<MTLCommandBuffer> sync = [queue commandBuffer];
                    [sync commit];
                    [sync waitUntilCompleted];
                    cpuFallback(j, static_cast<const float*>(src.contents), static_cast<float*>(dst.contents));
                    return true;
                }
                error = "Texture stage unavailable on the GPU (" + terr + "). See ~/Library/Logs/NodeOne/";
                return false;
            }
        }

        // Density Pro, same rule as the texture stage.
        DensityPsos denPs;
        if (j.density) {
            std::string derr;
            if (!j.scratch || !densityPipelines(dev, denPs, derr)) {
                if (src.storageMode == MTLStorageModeShared && dst.storageMode == MTLStorageModeShared) {
                    id<MTLCommandBuffer> sync = [queue commandBuffer];
                    [sync commit];
                    [sync waitUntilCompleted];
                    cpuFallback(j, static_cast<const float*>(src.contents), static_cast<float*>(dst.contents));
                    return true;
                }
                error = "Density Pro unavailable on the GPU (" + derr + "). See ~/Library/Logs/NodeOne/";
                return false;
            }
        }

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        cb.label = @"Node_One";

        // La sonde lit la source AVANT tout ce qui pourrait l'ecraser : quand la
        // source et la destination sont le meme tampon, l'etage ecrit dedans.
        // Spatial kernels must never read pixels they are writing.
        // La copie vit dans le tampon de travail de l'instance, garde d'une image
        // a l'autre : allouer un tampon de la taille de l'image a CHAQUE rendu
        // (130 Mo en 4K flottant) est une allocation lourde a chaque image. Un DCTL
        // per-pixel n'en a jamais besoin - il lit et ecrit le meme pixel.
        id<MTLBuffer> input = src;
        int inRow = j.srcRowFloats;
        if (j.density) {
            // Density Pro first, into the instance's own buffer.
            input = encodeDensity(cb, dev, denPs, *j.density, src, j.srcRowFloats, j.scratch);
            if (!input) {
                error = "could not allocate GPU buffers for Density Pro";
                return false;
            }
            inRow = j.width * 4;
        }
        if (j.texture) {
            // Grain and halation, into the instance's own buffer: the
            // DCTL then reads that buffer, never the one it writes.
            input = encodeTexture(cb, dev, texPs, *j.texture, input, inRow, j.scratch);
            if (!input) {
                error = "could not allocate GPU buffers for the texture stage";
                return false;
            }
            inRow = j.width * 4;
        } else if (!j.density && src == dst && j.def->spatial && j.scratch) {
            if (j.scratch->inputBytes < src.length) {
                j.scratch->input = [dev newBufferWithLength:src.length options:MTLResourceStorageModePrivate];
                j.scratch->inputBytes = j.scratch->input ? src.length : 0;
            }
            if (j.scratch->input) {
                input = j.scratch->input;
                id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                [blit copyFromBuffer:src sourceOffset:0 toBuffer:input destinationOffset:0 size:src.length];
                [blit endEncoding];
            }
        }

        // Without a LUT the DCTL writes the output directly; with one it writes
        // the log image into scratch and the LUT kernel finishes the picture.
        id<MTLBuffer> stageOut = j.lut ? j.scratch->buf[0] : dst;
        const int stageOutRow = j.lut ? j.width * 4 : j.dstRowFloats;

        // Skin mask pre-pass (see skinPasses): when its kernels are ready,
        // what each pixel brings to the mask is written once, then read.
        id<MTLBuffer> skinAux = nil;
        if (const int sp = j.scratch ? skinPasses(j.def, j.params) : 0) {
            id<MTLComputePipelineState> pre0 = specializedPipeline(dev, j.def, j.params, 0, 0);
            id<MTLComputePipelineState> pre1 = sp == 2 ? specializedPipeline(dev, j.def, j.params, 1, 0) : nil;
            id<MTLComputePipelineState> mainF = specializedPipeline(dev, j.def, j.params, -1, sp);
            if (pre0 && (sp == 1 || pre1) && mainF) {
                const NSUInteger plane = (NSUInteger)j.width * j.height * 4 * sizeof(float);
                if (j.scratch->skinBytes < plane * sp || !j.scratch->skin) {
                    j.scratch->skin = [dev newBufferWithLength:plane * sp options:MTLResourceStorageModePrivate];
                    j.scratch->skinBytes = j.scratch->skin ? plane * sp : 0;
                }
                if (j.scratch->skin) {
                    for (int p = 0; p < sp; ++p)
                        encodeStage(cb, p == 0 ? pre0 : pre1, j.params, j.def->paramsSize, input, inRow, j.scratch->skin,
                                    j.width * 4, j.width, j.height, j.flipY, nil, plane * p);
                    skinAux = j.scratch->skin;
                    pso = mainF;
                }
            }
        }
        encodeStage(cb, pso, j.params, j.def->paramsSize, input, inRow, stageOut, stageOutRow, j.width,
                    j.height, j.flipY, skinAux);
        if (j.lut)
            encodeLut(cb, lutPso, *j.lut, lutTable, stageOut, stageOutRow, dst, j.dstRowFloats, j.width, j.height);
        [cb commit];
        return true;
    }
}

bool metalRenderChain(const ChainMetalJob& j, std::string& error)
{
    @autoreleasepool {
        id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)j.commandQueue;
        id<MTLBuffer> src = (__bridge id<MTLBuffer>)j.srcBuffer;
        id<MTLBuffer> dst = (__bridge id<MTLBuffer>)j.dstBuffer;
        if (!queue || !src || !dst) {
            error = "missing Metal queue or image buffer";
            return false;
        }
        id<MTLDevice> dev = queue.device;

        // Nothing enabled: pass the picture through.
        if (j.nStages <= 0) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            if (src != dst) blitCopy(cb, src, j.srcRowFloats, dst, j.dstRowFloats, j.width, j.height);
            [cb commit];
            return true;
        }

        // Every stage's kernel must be ready, otherwise the whole chain runs on
        // the CPU: mixing the two per stage would cost more than it saves.
        std::vector<id<MTLComputePipelineState>> psos(j.nStages, nil);
        std::string firstError;
        bool allReady = true;
        for (int i = 0; i < j.nStages; ++i) {
            std::string e;
            psos[i] = specializedPipeline(dev, j.defs[i], j.params[i]);
            if (!psos[i]) psos[i] = pipeline(dev, j.defs[i], e);
            if (!psos[i]) {
                allReady = false;
                if (firstError.empty()) firstError = std::string(j.defs[i]->label) + ": " + e;
            }
        }
        if (!allReady) {
            if (src.storageMode == MTLStorageModeShared && dst.storageMode == MTLStorageModeShared) {
                id<MTLCommandBuffer> sync = [queue commandBuffer];
                [sync commit];
                [sync waitUntilCompleted];
                std::vector<float> tmp[2];
                cpuRenderChain(j.defs, j.params, j.nStages, static_cast<const float*>(src.contents), j.srcRowFloats,
                               static_cast<float*>(dst.contents), j.dstRowFloats, j.width, j.height, j.flipY, tmp);
                return true;
            }
            error = "Metal kernel unavailable (" + firstError + "). See ~/Library/Logs/NodeOne/";
            return false;
        }

        // Intermediate buffers, kept across frames. Stages read neighbouring
        // pixels, so a stage can never write into the buffer it is reading.
        const int tmpRowFloats = j.width * 4;
        const NSUInteger need = (NSUInteger)tmpRowFloats * j.height * sizeof(float);
        const bool aliased = (src == dst);
        const bool needScratch = (j.nStages > 1) || aliased;
        if (needScratch && !j.scratch) {
            error = "chain scratch buffers unavailable";
            return false;
        }
        if (needScratch && j.scratch->bytes < need) {
            j.scratch->buf[0] = [dev newBufferWithLength:need options:MTLResourceStorageModePrivate];
            j.scratch->buf[1] = [dev newBufferWithLength:need options:MTLResourceStorageModePrivate];
            if (!j.scratch->buf[0] || !j.scratch->buf[1]) {
                j.scratch->bytes = 0;
                error = "could not allocate GPU buffers for the chain";
                return false;
            }
            j.scratch->bytes = need;
        }

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        cb.label = @"Node_One Chain";

        // If the host handed us the same buffer in and out, take a copy first so
        // the first stage reads an untouched picture.
        id<MTLBuffer> in = src;
        int inRow = j.srcRowFloats;
        if (aliased) {
            blitCopy(cb, src, j.srcRowFloats, j.scratch->buf[1], tmpRowFloats, j.width, j.height);
            in = j.scratch->buf[1];
            inRow = tmpRowFloats;
        }

        for (int i = 0; i < j.nStages; ++i) {
            const bool last = (i == j.nStages - 1);
            id<MTLBuffer> out = last ? dst : j.scratch->buf[i & 1];
            const int outRow = last ? j.dstRowFloats : tmpRowFloats;
            encodeStage(cb, psos[i], j.params[i], j.defs[i]->paramsSize, in, inRow, out, outRow, j.width, j.height,
                        j.flipY);
            in = out;
            inRow = outRow;
        }
        [cb commit];
        return true;
    }
}



} // namespace nodeone
