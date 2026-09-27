// NODE_ONE OFX — Metal backend interface (implemented in NodeOneMetal.mm on macOS)
#pragma once
#include <string>
#include "plugin_def.h"

namespace nodeone {

struct Lut3D;
struct MetalScratch;

struct MetalJob {
    const PluginDef* def;
    const void* params;       // parameter block, def->paramsSize bytes
    const Lut3D* lut;         // optional 3D LUT stage after the DCTL, or null
    MetalScratch* scratch;    // required when lut is set
    void* commandQueue;       // id<MTLCommandQueue> from the host
    void* srcBuffer;          // id<MTLBuffer>
    void* dstBuffer;          // id<MTLBuffer>
    int width, height;
    int srcRowFloats, dstRowFloats;
    int flipY;
};

// Encodes the effect on the host queue. Returns false (with a message) if the
// kernel could not be built and no CPU fallback was possible.
bool metalRender(const MetalJob& job, std::string& error);

// ---- scratch -----------------------------------------------------------------
// Holds the intermediate GPU buffers the chain and the LUT stage need, kept per
// effect instance so they are not reallocated on every frame.
MetalScratch* metalScratchCreate();
void metalScratchDestroy(MetalScratch* s);

struct ChainMetalJob {
    const PluginDef* const* defs;   // enabled stages, in order
    const void* const* params;      // one parameter block per stage, same order
    int nStages;
    void* commandQueue;
    void* srcBuffer;
    void* dstBuffer;
    int width, height;
    int srcRowFloats, dstRowFloats;
    int flipY;
    MetalScratch* scratch;
};

// Encodes every stage into one command buffer. Returns false (with a message)
// if a kernel is missing and the CPU fallback could not run either; in that
// case the caller renders the chain on the CPU.
bool metalRenderChain(const ChainMetalJob& job, std::string& error);

// Starts compiling the effect's Metal kernel in the background so the first
// frame does not wait for it.
void metalPrewarm(const PluginDef& def);



} // namespace nodeone
