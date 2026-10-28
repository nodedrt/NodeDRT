// =============================================================================
//  NODE_DRT — Texture stage (Grain + Halation), host side
// -----------------------------------------------------------------------------
//  Runs on the camera log image before the display transform. The CPU path is
//  textureCPU(); the GPU path (NodeOneMetal.mm) runs the same passes with the
//  kernels of NodeTexture.metal and the same TexArgs / kernel tables, built here.
// =============================================================================
#pragma once
#include <cstddef>
#include <vector>
#include "NodeTextureMath.h"

namespace nodeone {

struct TextureSettings {
    bool grainOn = false;
    int gauge = 1;            // 0 = 65mm, 1 = 35mm
    float amount = 1.0f, size = 1.0f, colour = 1.0f, soft = 0.0f;
    float shadows = 1.0f, midtones = 1.0f, highlights = 1.0f;
    unsigned int seed = 0;
    bool halOn = false;
    float halStrength = 1.0f, halSize = 1.0f, halThreshold = 0.0f, halWarmth = 0.0f, halSoftness = 0.0f;
    int gamut = 15, oetf = 1; // the DCTL's input settings
    bool active() const { return (grainOn && amount > 0.0f) || (halOn && halStrength > 0.0f); }
};

struct TexturePlan {
    TexArgs a;
    std::vector<float> grK;   // 2 grR + 1 taps
    std::vector<float> halK;  // 6 x (2 halR + 1) taps
    std::vector<float> halSoftK;  // 2 halSoftR + 1 taps (gaussian, unit sum)
};

// Builds the arguments and kernel tables for a W x H frame.
void texturePlan(const TextureSettings& s, int W, int H, TexturePlan& plan);

// CPU texture stage: src (srcRowFloats) -> dst (W x 4 floats per row).
void textureCPU(const TexturePlan& plan, const float* src, ptrdiff_t srcRowFloats, float* dst, ptrdiff_t dstRowFloats);

} // namespace nodeone
