// =============================================================================
//  NODE_ONE OFX — all-in-one chain
// -----------------------------------------------------------------------------
//  One effect that runs several Node_One stages in a fixed order, as if their
//  nodes were stacked in Resolve. Each stage keeps its own DCTL code and its
//  own parameters; nothing is re-implemented here, the stages are composed
//  from the PluginDefs the generator already produced.
// =============================================================================
#pragma once
#include <cstddef>
#include <vector>
#include "NodeOnePlugin.h"
#include "plugin_def.h"

namespace nodeone {

struct ChainStage {
    const PluginDef* def;
    const char* prefix;   // parameter-name prefix, e.g. "n01" -> "n01_contrast"
    const char* label;    // Inspector label for the stage, e.g. "Node 01"
};

struct ChainDef {
    const char* identifier;
    const char* label;
    const char* grouping;
    const char* description;
    unsigned versionMajor, versionMinor;
    const ChainStage* stages;
    int nStages;
    const char* const* about;
    int nAbout;
};

void describeChain(const ChainDef& def, OFX::ImageEffectDescriptor& desc);
void describeChainInContext(const ChainDef& def, OFX::ImageEffectDescriptor& desc, OFX::ContextEnum ctx);
OFX::ImageEffect* createChainEffect(OfxImageEffectHandle handle, const ChainDef& def);

// One OFX factory for the chain effect.
template <int N>
class ChainFactory : public OFX::PluginFactoryHelper<ChainFactory<N>> {
public:
    explicit ChainFactory(const ChainDef& d)
        : OFX::PluginFactoryHelper<ChainFactory<N>>(d.identifier, d.versionMajor, d.versionMinor), _def(d) {}
    void load() override {}
    void unload() override {}
    void describe(OFX::ImageEffectDescriptor& desc) override { describeChain(_def, desc); }
    void describeInContext(OFX::ImageEffectDescriptor& desc, OFX::ContextEnum ctx) override
    {
        describeChainInContext(_def, desc, ctx);
    }
    OFX::ImageEffect* createInstance(OfxImageEffectHandle h, OFX::ContextEnum) override
    {
        return createChainEffect(h, _def);
    }

private:
    const ChainDef& _def;
};

} // namespace nodeone
