// =============================================================================
//  NODE_ONE OFX — generic OFX image effect driven by a PluginDef table
// -----------------------------------------------------------------------------
//  One class serves all Node_One effects. Each effect is described by the
//  tables generated from its DCTL (gen/<key>.cpp): parameters, groups, the
//  CPU kernel and the Metal source.
//  Rendering: Metal on the GPU when the host asks for it (DaVinci Resolve on
//  macOS), multithreaded CPU otherwise. Both run the same DCTL code.
// =============================================================================
#include "NodeOnePlugin.h"
#include <mutex>
#include "NodeOneLut.h"
#include "NodeOneMetal.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "ofxsImageEffect.h"

#ifndef NODEONE_BUILD_TAG
#define NODEONE_BUILD_TAG "dev"
#endif

// DCTL coordinates put the origin at the top-left; OFX puts row 0 at the
// bottom. 1 = convert (OFX-conformant hosts). Kept as a switch for hosts that
// hand GPU buffers top-down.
#ifndef NODEONE_FLIP_Y_CPU
#define NODEONE_FLIP_Y_CPU 1
#endif
#ifndef NODEONE_FLIP_Y_METAL
#define NODEONE_FLIP_Y_METAL 1
#endif

namespace nodeone {

static const char* const kSrcClip = kOfxImageEffectSimpleSourceClipName;
static const char* const kDstClip = kOfxImageEffectOutputClipName;

// The LUT menu saves an index, and the index would move if the LUT folder
// changed. The chosen LUT's name is stored alongside it so a grade reopened
// later still finds the LUT it was made with.
static const char* const kLutChoice = "nodeone_lut";
static const char* const kLutName = "nodeone_lut_name";
static const char* const kLutNone = "None — the plugin's own render";

static int digitsForStep(double step)
{
    if (step <= 0.0) return 3;
    int d = (int)std::ceil(-std::log10(step) - 1e-9);
    return std::max(0, std::min(6, d));
}

// -----------------------------------------------------------------------------
//  Effect instance
// -----------------------------------------------------------------------------
class NodeOneEffect : public OFX::ImageEffect {
public:
    NodeOneEffect(OfxImageEffectHandle handle, const PluginDef& def)
        : OFX::ImageEffect(handle), _def(def)
    {
        _dstClip = fetchClip(kDstClip);
        _srcClip = fetchClip(kSrcClip);
        _params.resize(def.nParams, nullptr);
        for (int i = 0; i < def.nParams; ++i) {
            const ParamSpec& p = def.params[i];
            if (p.group == -2) continue;   // fixe a son defaut, jamais defini
            switch (p.kind) {
                case kParamFloat: _params[i] = fetchDoubleParam(p.name); break;
                case kParamBool: _params[i] = fetchBooleanParam(p.name); break;
                case kParamChoice: _params[i] = fetchChoiceParam(p.name); break;
                case kParamPush: _params[i] = fetchPushButtonParam(p.name); break;
            }
        }
        if (def.lutLogModeParam) {
            _lutChoice = fetchChoiceParam(kLutChoice);
            _lutName = fetchStringParam(kLutName);
            syncLutChoiceFromName();
        }
        metalPrewarm(def);
        _scratch = metalScratchCreate();
    }

    ~NodeOneEffect() override
    {
        if (_scratch) metalScratchDestroy(_scratch);
    }

private:
    // The saved name wins over the saved index, so a grade survives LUTs being
    // added to or removed from the folder between sessions.
    void syncLutChoiceFromName()
    {
        if (!_lutChoice || !_lutName) return;
        std::string want;
        _lutName->getValue(want);
        if (want.empty()) return;
        const std::vector<LutEntry>& cat = lutCatalog();
        for (size_t i = 0; i < cat.size(); ++i)
            if (cat[i].name == want) {
                int cur = 0;
                _lutChoice->getValue(cur);
                if (cur != (int)i + 1) _lutChoice->setValue((int)i + 1);
                return;
            }
    }

    // Empty when no LUT is selected, or when the saved one is gone.
    std::string selectedLutPath(double t)
    {
        if (!_lutChoice) return std::string();
        const std::vector<LutEntry>& cat = lutCatalog();
        std::string want;
        if (_lutName) _lutName->getValueAtTime(t, want);
        if (!want.empty()) {
            for (const LutEntry& e : cat)
                if (e.name == want) return e.path;
            return std::string();
        }
        int idx = 0;
        _lutChoice->getValueAtTime(t, idx);
        if (idx <= 0 || idx > (int)cat.size()) return std::string();
        return cat[idx - 1].path;
    }

    // Cherche un parametre par nom. Rend nullptr quand l'effet ne l'a pas :
    // le meme code de plugin sert les huit effets, et un seul porte le bloc WB.
    OFX::Param* paramByName(const char* want) const
    {
        for (int i = 0; i < _def.nParams; ++i)
            if (std::strcmp(_def.params[i].name, want) == 0) return _params[i];
        return nullptr;
    }


    // RESET D'UN GROUPE. Le bouton lit la TABLE DES GROUPES, il ne porte pas une
    // liste de noms ecrite a la main : un reglage ajoute plus tard dans le meme
    // groupe est donc remis a zero lui aussi, sans que personne ait a y penser -
    // et un reglage deplace ailleurs cesse d'etre touche, ce qui est correct.
    // Tout se fait dans un seul bloc d'edition, donc une seule annulation.
    bool resetGroupOf(const std::string& buttonName)
    {
        int gi = -99;
        for (int i = 0; i < _def.nParams; ++i)
            if (std::strcmp(_def.params[i].name, buttonName.c_str()) == 0) { gi = _def.params[i].group; break; }
        if (gi == -99) return false;

        beginEditBlock("reset");
        for (int i = 0; i < _def.nParams; ++i) {
            const ParamSpec& p = _def.params[i];
            if (p.group != gi || !_params[i]) continue;
            if (p.offset == kNoOffset) continue;      // les synthetiques n'ont pas de valeur
            if (p.kind == kParamFloat)
                static_cast<OFX::DoubleParam*>(_params[i])->setValue(p.def);
            else if (p.kind == kParamBool)
                static_cast<OFX::BooleanParam*>(_params[i])->setValue(p.def != 0.0);
            else if (p.kind == kParamChoice)
                static_cast<OFX::ChoiceParam*>(_params[i])->setValue((int)std::lround(p.def));
        }
        endEditBlock();
        return true;
    }

    void changedParam(const OFX::InstanceChangedArgs& args, const std::string& name) override
    {
        // Tout bouton dont le nom finit par _reset remet son propre groupe a zero.
        if (name.size() > 6 && name.compare(name.size() - 6, 6, "_reset") == 0) {
            if (resetGroupOf(name)) return;
        }
        if (name != kLutChoice || !_lutChoice || !_lutName) {
            OFX::ImageEffect::changedParam(args, name);
            return;
        }
        int idx = 0;
        _lutChoice->getValue(idx);
        const std::vector<LutEntry>& cat = lutCatalog();
        _lutName->setValue(idx > 0 && idx <= (int)cat.size() ? cat[idx - 1].name : std::string());
    }

    void fillParams(double t, std::vector<uint32_t>& block)
    {
        block.assign(_def.paramsSize / 4, 0u);
        for (int i = 0; i < _def.nParams; ++i) {
            const ParamSpec& p = _def.params[i];
            // Un parametre SYNTHETIQUE n'existe que dans le plugin : il n'a pas
            // de place dans le bloc du kernel, donc rien a y ecrire.
            if (p.offset == kNoOffset) continue;
            uint32_t* slot = &block[p.offset / 4];
            if (p.kind == kParamFloat) {
                float v = (float)p.def;
                if (_params[i]) v = (float)static_cast<OFX::DoubleParam*>(_params[i])->getValueAtTime(t);
                std::memcpy(slot, &v, 4);
            } else {
                int32_t v = (int32_t)std::lround(p.def);
                if (_params[i]) {
                    if (p.kind == kParamBool) v = static_cast<OFX::BooleanParam*>(_params[i])->getValueAtTime(t) ? 1 : 0;
                    else static_cast<OFX::ChoiceParam*>(_params[i])->getValueAtTime(t, v);
                }
                std::memcpy(slot, &v, 4);
            }
        }
    }

    void render(const OFX::RenderArguments& args) override
    {
        std::unique_ptr<OFX::Image> dst(_dstClip->fetchImage(args.time));
        std::unique_ptr<OFX::Image> src(_srcClip->fetchImage(args.time));
        if (!dst || !src) OFX::throwSuiteStatusException(kOfxStatFailed);
        if (dst->getPixelDepth() != OFX::eBitDepthFloat || src->getPixelDepth() != OFX::eBitDepthFloat ||
            dst->getPixelComponents() != OFX::ePixelComponentRGBA ||
            src->getPixelComponents() != OFX::ePixelComponentRGBA)
            OFX::throwSuiteStatusException(kOfxStatErrImageFormat);

        const OfxRectI sb = src->getBounds();
        const OfxRectI db = dst->getBounds();
        if (sb.x1 != db.x1 || sb.y1 != db.y1 || sb.x2 != db.x2 || sb.y2 != db.y2)
            OFX::throwSuiteStatusException(kOfxStatErrImageFormat);
        const int W = sb.x2 - sb.x1, H = sb.y2 - sb.y1;
        if (W <= 0 || H <= 0) return;

        std::vector<uint32_t> block;
        fillParams(args.time, block);

        // A chosen LUT takes over the display rendering: the DCTL is switched to
        // its log output and the LUT finishes the picture.
        const Lut3D* lut = nullptr;
        if (_def.lutLogModeParam) {
            const std::string path = selectedLutPath(args.time);
            if (!path.empty()) {
                std::string err;
                lut = lutLoad(path, err);
                if (!lut) {
                    setPersistentMessage(OFX::Message::eMessageError, "", std::string(_def.label) + ": " + err);
                    OFX::throwSuiteStatusException(kOfxStatFailed);
                }
                for (int i = 0; i < _def.nParams; ++i)
                    if (std::strcmp(_def.params[i].name, _def.lutLogModeParam) == 0) {
                        const int32_t v = _def.lutLogModeValue;
                        std::memcpy(&block[_def.params[i].offset / 4], &v, 4);
                        break;
                    }
            }
        }

        if (args.isEnabledMetalRender && args.pMetalCmdQ) {
            MetalJob job;
            job.def = &_def;
            job.params = block.data();
            job.commandQueue = args.pMetalCmdQ;
            job.srcBuffer = src->getPixelData();
            job.dstBuffer = dst->getPixelData();
            job.width = W;
            job.height = H;
            job.srcRowFloats = src->getRowBytes() > 0 ? src->getRowBytes() / 4 : W * 4;
            job.dstRowFloats = dst->getRowBytes() > 0 ? dst->getRowBytes() / 4 : W * 4;
            job.flipY = NODEONE_FLIP_Y_METAL;
            job.lut = lut;
            job.scratch = _scratch;
            std::string err;
            if (!metalRender(job, err)) {
                setPersistentMessage(OFX::Message::eMessageError, "", std::string(_def.label) + ": " + err);
                OFX::throwSuiteStatusException(kOfxStatFailed);
            }
            return;
        }

        // ---- CPU -------------------------------------------------------------
        const float* sp = static_cast<const float*>(src->getPixelAddress(sb.x1, sb.y1));
        float* dp = static_cast<float*>(dst->getPixelAddress(db.x1, db.y1));
        const ptrdiff_t srf = src->getRowBytes() / (ptrdiff_t)sizeof(float);
        const ptrdiff_t drf = dst->getRowBytes() / (ptrdiff_t)sizeof(float);
        const OfxRectI rw = args.renderWindow;
        const int r0 = std::max(0, rw.y1 - sb.y1), r1 = std::min(H, rw.y2 - sb.y1);
        if (lut) {
            // DCTL into scratch, then the LUT into the output.
            _lutTmp.resize((size_t)W * 4 * H);
            cpuRender(_def, block.data(), sp, srf, _lutTmp.data(), (ptrdiff_t)W * 4, W, H, 0, H, NODEONE_FLIP_Y_CPU);
            lutApplyCPUThreaded(*lut, _lutTmp.data(), (ptrdiff_t)W * 4, dp, drf, W, H);
            return;
        }
        cpuRender(_def, block.data(), sp, srf, dp, drf, W, H, r0, r1, NODEONE_FLIP_Y_CPU);
    }

    bool isIdentity(const OFX::IsIdentityArguments&, OFX::Clip*&, double&) override { return false; }

    void getRegionsOfInterest(const OFX::RegionsOfInterestArguments& args, OFX::RegionOfInterestSetter& rois) override
    {
        // Spatial DCTLs may sample anywhere in the frame (the WB and Skin
        // checkers read the whole picture): always ask for the full source.
        if (_def.spatial) rois.setRegionOfInterest(*_srcClip, _srcClip->getRegionOfDefinition(args.time));
        else OFX::ImageEffect::getRegionsOfInterest(args, rois);
    }

    const PluginDef& _def;
    OFX::Clip* _dstClip = nullptr;
    OFX::Clip* _srcClip = nullptr;
    std::vector<OFX::Param*> _params;
    OFX::ChoiceParam* _lutChoice = nullptr;
    OFX::StringParam* _lutName = nullptr;
    std::vector<float> _lutTmp;
    MetalScratch* _scratch = nullptr;
};

// -----------------------------------------------------------------------------
//  CPU path — rows split across all cores
// -----------------------------------------------------------------------------
void cpuRender(const PluginDef& def, const void* params, const float* src, ptrdiff_t srcRowFloats, float* dst,
               ptrdiff_t dstRowFloats, int W, int H, int r0, int r1, int flipY)
{
    const int rows = r1 - r0;
    if (rows <= 0) return;
    unsigned n = std::max(1u, std::thread::hardware_concurrency());
    n = std::min<unsigned>(n, (unsigned)rows);
    if (n == 1) {
        def.cpuRender(params, src, srcRowFloats, dst, dstRowFloats, W, H, r0, r1, flipY);
        return;
    }
    std::vector<std::thread> pool;
    pool.reserve(n);
    for (unsigned i = 0; i < n; ++i) {
        const int a = r0 + (int)((long long)rows * i / n);
        const int b = r0 + (int)((long long)rows * (i + 1) / n);
        pool.emplace_back([=, &def] { def.cpuRender(params, src, srcRowFloats, dst, dstRowFloats, W, H, a, b, flipY); });
    }
    for (auto& t : pool) t.join();
}

// -----------------------------------------------------------------------------
//  CPU chain — ping-pong through two scratch buffers, last stage writes to dst
// -----------------------------------------------------------------------------
void cpuRenderChain(const PluginDef* const* defs, const void* const* params, int n, const float* src,
                    ptrdiff_t srcRow, float* dst, ptrdiff_t dstRow, int W, int H, int flipY,
                    std::vector<float> tmp[2])
{
    if (n <= 0) {
        for (int row = 0; row < H; ++row)
            std::memcpy(dst + row * dstRow, src + row * srcRow, (size_t)W * 4 * sizeof(float));
        return;
    }
    const ptrdiff_t tmpRow = (ptrdiff_t)W * 4;
    if (n > 1) tmp[0].resize((size_t)tmpRow * H);
    if (n > 2) tmp[1].resize((size_t)tmpRow * H);
    const float* in = src;
    ptrdiff_t inRow = srcRow;
    for (int i = 0; i < n; ++i) {
        const bool last = (i == n - 1);
        float* out = last ? dst : tmp[i & 1].data();
        const ptrdiff_t outRow = last ? dstRow : tmpRow;
        cpuRender(*defs[i], params[i], in, inRow, out, outRow, W, H, 0, H, flipY);
        in = out;
        inRow = outRow;
    }
}

// -----------------------------------------------------------------------------
//  Description
// -----------------------------------------------------------------------------
void describePlugin(const PluginDef& def, OFX::ImageEffectDescriptor& desc)
{
    desc.setLabels(def.label, def.label, def.label);
    desc.setPluginGrouping(def.grouping);
    desc.setPluginDescription(def.description);
    desc.addSupportedContext(OFX::eContextFilter);
    desc.addSupportedContext(OFX::eContextGeneral);
    desc.addSupportedBitDepth(OFX::eBitDepthFloat);
    desc.setSingleInstance(false);
    desc.setHostFrameThreading(false);
    desc.setSupportsMultiResolution(false);
    desc.setSupportsTiles(false);
    desc.setTemporalClipAccess(false);
    desc.setRenderTwiceAlways(false);
    desc.setSupportsMultipleClipPARs(false);
    desc.setRenderThreadSafety(OFX::eRenderFullySafe);
#if defined(__APPLE__)
    desc.setSupportsMetalRender(true);
#endif
}

void describePluginInContext(const PluginDef& def, OFX::ImageEffectDescriptor& desc, OFX::ContextEnum)
{
    OFX::ClipDescriptor* src = desc.defineClip(kSrcClip);
    src->addSupportedComponent(OFX::ePixelComponentRGBA);
    src->setTemporalClipAccess(false);
    src->setSupportsTiles(false);
    src->setIsMask(false);

    OFX::ClipDescriptor* dst = desc.defineClip(kDstClip);
    dst->addSupportedComponent(OFX::ePixelComponentRGBA);
    dst->setSupportsTiles(false);

    OFX::PageParamDescriptor* page = desc.definePageParam("Controls");

    std::vector<OFX::GroupParamDescriptor*> groups;
    for (int g = 0; g < def.nGroups; ++g) {
        OFX::GroupParamDescriptor* gp = desc.defineGroupParam(def.groups[g].name);
        gp->setLabels(def.groups[g].label, def.groups[g].label, def.groups[g].label);
        gp->setOpen(def.groups[g].open != 0);
        groups.push_back(gp);
    }

    // Parameters in group order, so the Inspector reads top to bottom.
    for (int g = -1; g < def.nGroups; ++g) {
        if (g >= 0) page->addChild(*groups[g]);

        // The LUT menu belongs with the Look controls: choosing a print LUT is
        // choosing a look, and it replaces the renderer that the looks drive.
        const bool lutHere = def.lutLogModeParam &&
                             ((g < 0 && !def.lutGroup) ||
                              (g >= 0 && def.lutGroup && std::strcmp(def.groups[g].name, def.lutGroup) == 0));
        if (lutHere) {
            OFX::ChoiceParamDescriptor* c = desc.defineChoiceParam(kLutChoice);
            c->setLabels("Print Film LUT", "Print Film LUT", "Print Film LUT");
            c->setHint("A print LUT is a display rendering of its own, so choosing one replaces the plugin's "
                       "own render: the picture is converted to the gamut and log curve set below and handed to "
                       "the LUT. Off returns to the plugin's render and the Look menu.");
            c->appendOption(kLutNone);
            for (const LutEntry& e : lutCatalog()) c->appendOption(e.name);
            c->setDefault(0);
            c->setAnimates(false);
            if (g >= 0) c->setParent(*groups[g]);
            page->addChild(*c);

            // Hidden companion: remembers the LUT by name, not by position.
            OFX::StringParamDescriptor* n = desc.defineStringParam(kLutName);
            n->setLabels("", "", "");
            n->setDefault("");
            n->setIsSecret(true);
            n->setAnimates(false);
            n->setEvaluateOnChange(false);
            if (g >= 0) n->setParent(*groups[g]);
            page->addChild(*n);
        }
        for (int i = 0; i < def.nParams; ++i) {
            const ParamSpec& p = def.params[i];
            if (p.group != g) continue;
            // Un bouton n'est pas un ValueParamDescriptor : il derive directement
            // de ParamDescriptor et n'a ni valeur ni animation. On garde donc les
            // deux pointeurs, le commun pour le libelle et le parent, le second
            // pour ce qui n'existe que sur un parametre porteur de valeur.
            OFX::ParamDescriptor* pd = nullptr;
            OFX::ValueParamDescriptor* vp = nullptr;
            if (p.kind == kParamFloat) {
                OFX::DoubleParamDescriptor* d = desc.defineDoubleParam(p.name);
                d->setDoubleType(OFX::eDoubleTypePlain);
                d->setDefault(p.def);
                d->setRange(p.min, p.max);
                d->setDisplayRange(p.min, p.max);
                d->setIncrement(p.step > 0 ? p.step : 0.001);
                d->setDigits(digitsForStep(p.step));
                // Un flottant SYNTHETIQUE est un afficheur, pas un reglage : le
                // score de confiance de l'analyse est ecrit par le plugin et n'a
                // pas de sens si l'utilisateur le change. Il est donc grise, et il
                // ne s'anime pas.
                if (p.offset == kNoOffset) { d->setEnabled(false); d->setAnimates(false); }
                vp = d;
            } else if (p.kind == kParamBool) {
                OFX::BooleanParamDescriptor* b = desc.defineBooleanParam(p.name);
                b->setDefault(p.def != 0.0);
                vp = b;
            } else if (p.kind == kParamPush) {
                pd = desc.definePushButtonParam(p.name);
            } else {
                OFX::ChoiceParamDescriptor* c = desc.defineChoiceParam(p.name);
                for (int o = 0; o < p.nOptions; ++o) c->appendOption(p.options[o]);
                c->setDefault((int)std::lround(p.def));
                vp = c;
            }
            if (vp) { if (!(p.kind == kParamFloat && p.offset == kNoOffset)) vp->setAnimates(true); pd = vp; }
            if (!pd) continue;
            pd->setLabels(p.label, p.label, p.label);
            if (p.hint && *p.hint) pd->setHint(p.hint);
            if (g >= 0) pd->setParent(*groups[g]);
            page->addChild(*pd);
        }
    }

    // About — read-only text, collapsed.
    OFX::GroupParamDescriptor* about = desc.defineGroupParam("grp_about");
    about->setLabels("About", "About", "About");
    about->setOpen(false);
    page->addChild(*about);
    std::vector<std::string> lines;
    for (int i = 0; i < def.nAbout; ++i) lines.push_back(def.about[i]);
    if (def.lutLogModeParam) {
        size_t bundled = 0;
        for (const LutEntry& e : lutCatalog())
            if (e.bundled) ++bundled;
        const size_t onDisk = lutCatalog().size() - bundled;
        if (bundled)
            lines.push_back(std::to_string(bundled) + " print LUTs travel inside this plugin, plus " +
                            std::to_string(onDisk) + " found in your Resolve LUT folders. The bundled ones are "
                            "Blackmagic Design's, licensed to you with Resolve: this build is for your machine, "
                            "not for passing on.");
        else
            lines.push_back(std::to_string(onDisk) + " LUTs found in your Resolve LUT folders. "
                            "None are built into this plugin.");
    }
    lines.push_back(std::string("Build ") + NODEONE_BUILD_TAG + (def.metalSource ? " — Metal GPU + CPU" : " — CPU"));
    for (size_t i = 0; i < lines.size(); ++i) {
        OFX::StringParamDescriptor* s = desc.defineStringParam("about_" + std::to_string(i));
        s->setLabels("", "", "");
        s->setStringType(OFX::eStringTypeLabel);
        s->setDefault(lines[i]);
        s->setHint(lines[i]);
        s->setAnimates(false);
        s->setEvaluateOnChange(false);
        s->setIsPersistant(false);
        // Greyed on purpose. These are credits, not controls: greying them
        // says so at a glance and stops anyone mistaking a line for something
        // they can set. Nothing is stored either way — editing a line changes
        // nothing and it returns on reopen — so this is purely about how the
        // panel reads.
        s->setEnabled(false);
        s->setParent(*about);
        page->addChild(*s);
    }
}

OFX::ImageEffect* createEffect(OfxImageEffectHandle handle, const PluginDef& def)
{
    return new NodeOneEffect(handle, def);
}

} // namespace nodeone
