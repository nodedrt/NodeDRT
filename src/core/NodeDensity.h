// =============================================================================
//  NODE_DRT — Density Pro stage, host side
// -----------------------------------------------------------------------------
//  Density by zone and by colour, from RELIEF. Runs on the camera log image
//  before the Texture stage and the display transform. The CPU path is
//  densityCPU(); the GPU path (NodeOneMetal.mm) runs the same passes with the
//  kernels of NodeDensity.metal and the same DensArgs, built here.
// =============================================================================
#pragma once
#include <cstddef>
#include "NodeTextureMath.h"
#include "NodeDensityMath.h"

namespace nodeone {

struct DensitySettings {
    bool on = false;          // section not bypassed
    bool show = false;        // Show Mask
    int maskFocus = -1;       // slider last touched (see DensArgs)
    float zone[3] = {0.0f, 0.0f, 0.0f};                 // shadows, midtones, highlights
    float hue[6] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};  // R Y G C B M
    float range[6] = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
    float boost = 0.0f, focus = 40.0f, zpiv = 0.0f, zsoft = 0.5f;
    float zonesSmooth = 0.0f, colorsSmooth = 0.0f;   // Mask Smoothness of each sub-section
    int gamut = 15, oetf = 1;  // the DCTL's input settings
    bool active() const
    {
        if (!on) return false;
        if (show) return true;
        for (float z : zone) if (z != 0.0f) return true;
        for (float h : hue) if (h != 0.0f) return true;
        return false;
    }
};

struct DensityPlan {
    DensArgs a;
};

// Builds the arguments for a W x H frame (matrices, tone-safety scale, blur).
void densityPlan(const DensitySettings& s, int W, int H, DensityPlan& plan);

// CPU stage: src (srcRowFloats) -> dst (dstRowFloats), RGBA.
void densityCPU(const DensityPlan& plan, const float* src, ptrdiff_t srcRowFloats, float* dst, ptrdiff_t dstRowFloats);

} // namespace nodeone
