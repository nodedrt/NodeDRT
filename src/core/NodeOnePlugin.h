// NODE_ONE OFX — shared declarations
#pragma once
#include <cstddef>
#include <vector>
#include "ofxsImageEffect.h"
#include "plugin_def.h"

namespace nodeone {

void describePlugin(const PluginDef& def, OFX::ImageEffectDescriptor& desc);
void describePluginInContext(const PluginDef& def, OFX::ImageEffectDescriptor& desc, OFX::ContextEnum ctx);
OFX::ImageEffect* createEffect(OfxImageEffectHandle handle, const PluginDef& def);
void cpuRender(const PluginDef& def, const void* params, const float* src, ptrdiff_t srcRowFloats, float* dst,
               ptrdiff_t dstRowFloats, int W, int H, int rowBegin, int rowEnd, int flipY);

// Runs several effects in order on the CPU, ping-ponging through `tmp` (two
// buffers, grown as needed). Used by the all-in-one chain and as the fallback
// when a GPU kernel is unavailable, so it lives here: both bundles link it.
// n == 0 copies the picture through unchanged.
void cpuRenderChain(const PluginDef* const* defs, const void* const* params, int n, const float* src,
                    ptrdiff_t srcRow, float* dst, ptrdiff_t dstRow, int W, int H, int flipY,
                    std::vector<float> tmp[2]);

// One OFX factory per effect. The template index gives every effect its own
// static entry point, as the OFX support library requires.
template <int N>
class Factory : public OFX::PluginFactoryHelper<Factory<N>> {
public:
    explicit Factory(const PluginDef& d)
        : OFX::PluginFactoryHelper<Factory<N>>(d.identifier, d.versionMajor, d.versionMinor), _def(d) {}
    void load() override {}
    void unload() override {}
    void describe(OFX::ImageEffectDescriptor& desc) override { describePlugin(_def, desc); }
    void describeInContext(OFX::ImageEffectDescriptor& desc, OFX::ContextEnum ctx) override
    {
        describePluginInContext(_def, desc, ctx);
    }
    OFX::ImageEffect* createInstance(OfxImageEffectHandle h, OFX::ContextEnum) override { return createEffect(h, _def); }

private:
    const PluginDef& _def;
};

} // namespace nodeone
