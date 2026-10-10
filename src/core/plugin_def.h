// =============================================================================
//  NODE_ONE OFX — plugin definition tables (filled by tools/dctl2ofx.py)
// =============================================================================
#pragma once
#include <cstddef>

namespace nodeone {

enum ParamKind { kParamFloat = 0, kParamBool = 1, kParamChoice = 2, kParamPush = 3 };

// A SYNTHETIC parameter has no DCTL counterpart: it exists only in the plugin,
// so there is no slot for it in the kernel parameter block. The push button that
// runs the white balance analysis and the read-only field that reports its
// confidence are both of this kind. fillParams skips them by this offset.
static const unsigned kNoOffset = 0xFFFFFFFFu;

struct ParamSpec {
    const char* name;          // OFX parameter name == DCTL identifier (stable, never rename)
    const char* label;         // Inspector label
    const char* hint;          // tooltip
    int kind;                  // ParamKind
    double def, min, max, step;
    const char* const* options;
    int nOptions;
    int group;                 // index into groups, -1 = top level, -2 = hidden (fixed at default)
    unsigned offset;           // byte offset in the kernel parameter block
};

struct GroupSpec {
    const char* name;
    const char* label;
    int open;                  // expanded by default
    int parent;                // index of the enclosing group, -1 = top level.
                               // A sub-group is a standard OFX group nested in
                               // its parent: a collapsible sub-section.
};

typedef void (*CpuRenderFn)(const void* params,
                            const float* src, ptrdiff_t srcRowFloats,
                            float* dst, ptrdiff_t dstRowFloats,
                            int width, int height, int rowBegin, int rowEnd, int flipY);

struct PluginDef {
    const char* identifier;
    const char* label;
    const char* grouping;
    const char* description;
    unsigned versionMajor, versionMinor;
    const GroupSpec* groups; int nGroups;
    const ParamSpec* params; int nParams;
    size_t paramsSize;
    const char* metalSource;
    const char* metalKernelName;
    CpuRenderFn cpuRender;
    int spatial;               // reads neighbouring pixels (texture DCTL)
    const char* const* about; int nAbout;
    // Optional 3D LUT stage. When the user picks a LUT, the plugin forces this
    // DCTL parameter to lutLogModeValue so the DCTL stops at a log image and
    // the LUT does the display rendering. Null when the effect has no LUT menu.
    const char* lutLogModeParam;
    int lutLogModeValue;
    const char* lutGroup;      // group the LUT menu sits in, null for top level
};

} // namespace nodeone
