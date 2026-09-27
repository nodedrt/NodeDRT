// =============================================================================
//  NODE_ONE OFX — non-Apple builds: no Metal, the host always renders on CPU.
// =============================================================================
#include "NodeOneLut.h"
#include "NodeOneMetal.h"
#include "NodeOnePlugin.h"

namespace nodeone {

bool metalRender(const MetalJob&, std::string& error)
{
    error = "Metal is not available on this platform";
    return false;
}
void metalPrewarm(const PluginDef&) {}



struct MetalScratch {
    int unused;
};
MetalScratch* metalScratchCreate() { return nullptr; }
void metalScratchDestroy(MetalScratch*) {}

bool metalRenderChain(const ChainMetalJob&, std::string& error)
{
    error = "Metal is not available on this platform";
    return false;
}

// The real Metal backend falls back to these shared helpers, so every bundle
// that links a backend must also provide them. This table makes that same
// requirement exist on platforms built with the stub: a helper that lives in
// the wrong translation unit then fails the link everywhere, instead of only
// on macOS where it would be found late and by the person building.
// extern first: a const array at namespace scope would otherwise have internal
// linkage, be dropped as unused, and quietly guard nothing.
extern void* const kNodeOneLinkGuard[];
void* const kNodeOneLinkGuard[] = {
    (void*)&cpuRender,
    (void*)&cpuRenderChain,
    (void*)&lutApplyCPUThreaded,
    (void*)&lutLoad,
};

} // namespace nodeone
