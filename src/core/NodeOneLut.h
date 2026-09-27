// =============================================================================
//  NODE_ONE OFX — 3D LUT stage
// -----------------------------------------------------------------------------
//  No LUT data is built into this plugin. The .cube files are read from disk at
//  render time, from the places Resolve keeps them, so every user applies the
//  LUTs they are licensed to use and this source stays freely redistributable.
//  Interpolation is tetrahedral, which is what Resolve uses by default, so a
//  LUT applied here matches the same LUT applied in a Resolve LUT node.
// =============================================================================
#pragma once
#include <cstddef>
#include <string>
#include <vector>

namespace nodeone {

struct Lut3D {
    int size = 0;                       // N of an N x N x N cube
    float domainMin[3] = {0.f, 0.f, 0.f};
    float domainMax[3] = {1.f, 1.f, 1.f};
    std::vector<float> data;            // N^3 * 3, red varies fastest
    std::string title;
};

// A .cube file found on disk. `name` is what the menu shows.
struct LutEntry {
    std::string name;
    std::string path;
    bool bundled = false;   // carried inside the plugin bundle
};

// The LUTs carried inside the plugin bundle first, then every .cube found under
// the Resolve LUT folders. Sorted within each group so a saved grade keeps
// pointing at the same entry. Scanned once per session.
const std::vector<LutEntry>& lutCatalog();

// Parses a .cube file. Returns false and fills `error` on a malformed file.
bool lutParseCube(const std::string& path, Lut3D& out, std::string& error);

// Loads and caches by path. Returns nullptr and fills `error` on failure;
// a failure is remembered so a broken file is not re-read every frame.
const Lut3D* lutLoad(const std::string& path, std::string& error);

// Tetrahedral sampling of one RGB triple, input clamped to the LUT domain.
void lutSample(const Lut3D& lut, const float in[3], float out[3]);

// Applies the LUT over rows [rowBegin, rowEnd) of an RGBA float image.
// Alpha is carried through untouched.
void lutApplyCPU(const Lut3D& lut, const float* src, ptrdiff_t srcRowFloats, float* dst, ptrdiff_t dstRowFloats,
                 int width, int rowBegin, int rowEnd);

// Same, spread over all cores.
void lutApplyCPUThreaded(const Lut3D& lut, const float* src, ptrdiff_t srcRowFloats, float* dst,
                         ptrdiff_t dstRowFloats, int width, int height);

} // namespace nodeone
