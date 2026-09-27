// =============================================================================
//  NODE_DRT — registration for its OWN bundle.
// -----------------------------------------------------------------------------
//  NODE_DRT is a modified OpenDRT v1.0.1 (Jed Smith) and is therefore GPLv3.
//  It ships in a bundle of its own, NodeDRT.ofx.bundle, and NOTHING else goes
//  in it.
//
//  That separation is the whole point, and it is not bureaucracy: the GPL
//  reaches everything linked into the same binary. Put this plugin in
//  NodeOne.ofx.bundle and Node 01, Split Sculptor, Chroma Drive, Skin, White
//  Balance, Composite and Node One DRT would all fall under the GPL with it,
//  and their source would have to ship too. Two bundles, one obligation.
//
//  Selling this one is allowed. Publishing its complete source, under GPLv3,
//  is the condition — see licenses/GPL-3.0.txt and licenses/NOTICE-NodeDRT.txt.
// =============================================================================
#include "NodeOnePlugin.h"

namespace nodeone {
extern const PluginDef kPlugin_drt;       // NODE_DRT — OpenDRT derived, GPLv3
}

namespace OFX {
namespace Plugin {
void getPluginIDs(OFX::PluginFactoryArray& ids)
{
    using namespace nodeone;
    static Factory<0> f0(kPlugin_drt);
    ids.push_back(&f0);
}
}  // namespace Plugin
}  // namespace OFX
