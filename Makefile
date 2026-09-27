# =============================================================================
#  NODE_DRT — build (macOS, Apple clang from the Xcode Command Line Tools)
# -----------------------------------------------------------------------------
#  Produces ONE universal (arm64 + x86_64) OFX bundle:
#      build/NodeDRT.ofx.bundle
#
#  This is the complete build for NODE_DRT, and it is self-contained: nothing
#  outside this directory is needed. Run `./build.sh` (or `make`), then
#  `./build.sh install` to copy the bundle into /Library/OFX/Plugins.
#
#  WHY THIS IS A BUNDLE OF ITS OWN. NODE_DRT is a modified OpenDRT v1.0.1 and is
#  therefore GPLv3. The GPL reaches everything linked into the same binary, so
#  NODE_DRT ships alone: that is what keeps the obligation to exactly this
#  plugin. Everything you can see in this repository is under GPLv3 (or a
#  licence compatible with it, see licenses/).
# =============================================================================
BUILD_TAG ?= gpl
ARCHS     ?= -arch arm64 -arch x86_64
MINOS     ?= -mmacosx-version-min=11.0
CXX       ?= clang++
CXXFLAGS  := -std=c++17 -O2 -fPIC -fvisibility=hidden -fvisibility-inlines-hidden $(ARCHS) $(MINOS) \
             -Iopenfx/include -Iopenfx/Support/include -Isrc/core -Igen -DNODEONE_BUILD_TAG='"$(BUILD_TAG)"' \
             -Wno-deprecated-declarations
OBJCFLAGS := $(CXXFLAGS) -fobjc-arc
LDFLAGS   := -bundle $(ARCHS) $(MINOS) -framework Metal -framework Foundation

O := build/obj
SUPPORT := ofxsCore ofxsImageEffect ofxsInteract ofxsLog ofxsMultiThread ofxsParams ofxsProperty ofxsPropertyValidation
OBJS := $(addprefix $(O)/,$(addsuffix .o,$(SUPPORT))) \
        $(O)/NodeOnePlugin.o $(O)/NodeOneMetal.o $(O)/NodeOneLut.o \
        $(O)/bundle_drt_main.o $(O)/gen_drt.o

BIN := build/NodeDRT.ofx.bundle/Contents/MacOS/NodeDRT.ofx

all: $(BIN)

# ---- the generated kernels ---------------------------------------------------
# gen/drt.cpp (CPU) and gen/drt.metal (GPU) are produced from dctl/NODE_DRT.dctl
# by tools/dctl2ofx.py. They are checked in so the bundle builds without Python,
# but they are DERIVED: edit the DCTL, never the generated files.
GENSRC := dctl/NODE_DRT.dctl tools/dctl2ofx.py tools/ui_layout.py src/core/dctl_metal_prelude.metal

gen/drt.cpp gen/drt.metal: $(GENSRC)
	python3 tools/dctl2ofx.py drt

regen:
	python3 tools/dctl2ofx.py drt
.PHONY: regen

$(O)/%.o: openfx/Support/Library/%.cpp | $(O)
	$(CXX) $(CXXFLAGS) -c $< -o $@
$(O)/NodeOnePlugin.o: src/core/NodeOnePlugin.cpp src/core/*.h | $(O)
	$(CXX) $(CXXFLAGS) -c $< -o $@
$(O)/NodeOneLut.o: src/core/NodeOneLut.cpp src/core/*.h | $(O)
	$(CXX) $(CXXFLAGS) -c $< -o $@
$(O)/NodeOneMetal.o: src/core/NodeOneMetal.mm src/core/*.h gen/lut_metal_src.h | $(O)
	$(CXX) $(OBJCFLAGS) -c $< -o $@
$(O)/bundle_drt_main.o: src/bundle_drt_main.cpp src/core/*.h | $(O)
	$(CXX) $(CXXFLAGS) -c $< -o $@
$(O)/gen_drt.o: gen/drt.cpp src/core/dctl_cpu.h src/core/plugin_def.h | $(O)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BIN): $(OBJS) resources/Info.plist
	mkdir -p $(dir $@) build/NodeDRT.ofx.bundle/Contents/Resources
	cp licenses/NOTICE-NodeDRT.txt licenses/GPL-3.0.txt licenses/BSD-3-OpenFX.txt \
	   licenses/MIT-SubtractiveSaturation.txt \
	   licenses/SPEKTRAFILM_LICENSE.txt licenses/TRADEMARKS.txt build/NodeDRT.ofx.bundle/Contents/Resources/
	sed -e 's/@NAME@/NodeDRT/g' -e 's/@ID@/com.nodeone.ofx.drt/g' -e 's/@VERSION@/$(BUILD_TAG)/g' \
	    resources/Info.plist > build/NodeDRT.ofx.bundle/Contents/Info.plist
	$(CXX) $(LDFLAGS) -o $@ $(filter %.o,$^)

$(O):
	mkdir -p $(O)

clean:
	rm -rf build

.PHONY: all clean
