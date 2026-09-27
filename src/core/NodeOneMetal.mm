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
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "NodeOneLut.h"
#include "NodeOneMetal.h"
#include "NodeOneChain.h"
#include "NodeOnePlugin.h"
#include "lut_metal_src.h"

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
};

MetalScratch* metalScratchCreate() { return new MetalScratch(); }

void metalScratchDestroy(MetalScratch* s)
{
    if (!s) return;
    @autoreleasepool {
        s->buf[0] = nil;
        s->buf[1] = nil;
        s->lutBuf = nil;
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
                 id<MTLBuffer> in, int inRowFloats, id<MTLBuffer> out, int outRowFloats, int W, int H, int flipY)
{
    KernelDims d = {W, H, inRowFloats, outRowFloats, flipY, 0, 0, 0};
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setBytes:params length:paramsSize atIndex:0];
    [enc setBuffer:in offset:0 atIndex:1];
    [enc setBuffer:out offset:0 atIndex:2];
    [enc setBytes:&d length:sizeof(d) atIndex:3];
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

} // namespace

void metalPrewarm(const PluginDef& def)
{
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev) startCompile(dev, &def);
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
        id<MTLComputePipelineState> pso = pipeline(dev, j.def, perr);

        if (!pso) {
            // Kernel unavailable: run the CPU path on shared memory if possible.
            if (src.storageMode == MTLStorageModeShared && dst.storageMode == MTLStorageModeShared) {
                id<MTLCommandBuffer> sync = [queue commandBuffer];
                [sync commit];
                [sync waitUntilCompleted];
                cpuRender(*j.def, j.params, static_cast<const float*>(src.contents), j.srcRowFloats,
                          static_cast<float*>(dst.contents), j.dstRowFloats, j.width, j.height, 0, j.height, j.flipY);
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
                    std::vector<float> tmp((size_t)j.width * 4 * j.height);
                    cpuRender(*j.def, j.params, static_cast<const float*>(src.contents), j.srcRowFloats, tmp.data(),
                              (ptrdiff_t)j.width * 4, j.width, j.height, 0, j.height, j.flipY);
                    lutApplyCPUThreaded(*j.lut, tmp.data(), (ptrdiff_t)j.width * 4,
                                        static_cast<float*>(dst.contents), j.dstRowFloats, j.width, j.height);
                    return true;
                }
                error = "LUT stage unavailable on the GPU (" + lerr + "). See ~/Library/Logs/NodeOne/";
                return false;
            }
        }

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        cb.label = @"Node_One";

        // La sonde lit la source AVANT tout ce qui pourrait l'ecraser : quand la
        // source et la destination sont le meme tampon, l'etage ecrit dedans.
        // Spatial kernels must never read pixels they are writing.
        id<MTLBuffer> input = src;
        if (src == dst && j.def->spatial) {
            input = [dev newBufferWithLength:src.length options:MTLResourceStorageModePrivate];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromBuffer:src sourceOffset:0 toBuffer:input destinationOffset:0 size:src.length];
            [blit endEncoding];
        }

        // Without a LUT the DCTL writes the output directly; with one it writes
        // the log image into scratch and the LUT kernel finishes the picture.
        id<MTLBuffer> stageOut = j.lut ? j.scratch->buf[0] : dst;
        const int stageOutRow = j.lut ? j.width * 4 : j.dstRowFloats;
        encodeStage(cb, pso, j.params, j.def->paramsSize, input, j.srcRowFloats, stageOut, stageOutRow, j.width,
                    j.height, j.flipY);
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
            psos[i] = pipeline(dev, j.defs[i], e);
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
