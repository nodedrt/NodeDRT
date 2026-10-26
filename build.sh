#!/bin/bash
# =============================================================================
#  NODE_DRT — build, check and (optionally) install on macOS
#
#    ./build.sh            build the bundle + check the Metal kernel
#    ./build.sh install    ... then copy it to /Library/OFX/Plugins (asks for
#                          your password) — restart Resolve afterwards
#    ./build.sh clean      remove build/
#    TRIAL=1 ./build.sh    build the 30-day trial instead of the full plugin
#
#  Needs the Xcode Command Line Tools:  xcode-select --install
#  Python 3 is optional: the generated kernels are checked in, and are only
#  regenerated from dctl/NODE_DRT.dctl if python3 is present.
#  Full log: build/build.log
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "clean" ]; then rm -rf build; echo "clean."; exit 0; fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools missing. Run:  xcode-select --install"; exit 1
fi

mkdir -p build
LOG=build/build.log
TAG="$(date +%Y.%m.%d.%H%M)"
TRIAL="${TRIAL:-0}"
# The trial flag rides on the compiler command, so the Makefile stays as is.
TCXX="clang++"; [ "$TRIAL" = 1 ] && TCXX="clang++ -DNODEDRT_TRIAL=1"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
{
  echo "== NODE_DRT build $TAG on $(sw_vers -productVersion) $(uname -m)"
  clang++ --version | head -1
} > "$LOG"

step() { printf "\033[1m%s\033[0m\n" "$1"; echo "== $1" >> "$LOG"; }

if command -v python3 >/dev/null 2>&1; then
  step "1/4  Generating the kernels from dctl/NODE_DRT.dctl"
  python3 tools/dctl2ofx.py drt >> "$LOG" 2>&1 || { echo "generator failed:"; tail -5 "$LOG"; exit 1; }
else
  step "1/4  python3 not found — using the generated code shipped in gen/"
fi

# Objects built for another architecture (or with other flags) must never be
# reused: the linker would silently drop them and report every symbol missing.
stamp_objects() {
  local want="$1" stamp="build/obj/.buildflags"
  if [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
    rm -rf build/obj
  fi
  mkdir -p build/obj
  printf '%s' "$want" > "$stamp"
}

step "2/4  Compiling (universal arm64 + x86_64, $JOBS jobs)"
stamp_objects "trial=$TRIAL arm64+x86_64 $(clang++ --version | head -1)"
if ! make -j"$JOBS" CXX="$TCXX" BUILD_TAG="$TAG" >> "$LOG" 2>&1; then
  # A Mac without the second architecture's SDK slice cannot build universal.
  # That is not a code problem: rebuild for this Mac only.
  echo "  universal build failed — retrying for this Mac only ($(uname -m))"
  echo "== retry: native arch only" >> "$LOG"
  rm -rf build/NodeDRT.ofx.bundle
  stamp_objects "trial=$TRIAL $(uname -m) $(clang++ --version | head -1)"
  if ! make -j"$JOBS" CXX="$TCXX" BUILD_TAG="$TAG" ARCHS="-arch $(uname -m)" >> "$LOG" 2>&1; then
    echo "BUILD FAILED — errors:"; grep -E "error" "$LOG" | head -30
    echo; echo "Full log: $LOG"; exit 1
  fi
  echo "  built for $(uname -m) only (this Mac)"
fi

step "3/4  Checking the Metal kernel on this GPU"
if [ ! -x build/metal_check ]; then
  clang++ -std=c++17 -O1 -fobjc-arc -mmacosx-version-min=11.0 tools/metal_check.mm \
          -o build/metal_check -framework Metal -framework Foundation >> "$LOG" 2>&1
fi
if ! build/metal_check gen/drt.metal 2>&1 | tee -a "$LOG"; then
  echo "METAL CHECK FAILED — see $LOG"; exit 1
fi

step "4/4  Signing (ad-hoc)"
codesign --force --deep --sign - build/NodeDRT.ofx.bundle >> "$LOG" 2>&1 \
  || { echo "codesign failed"; exit 1; }

echo
echo "Built:  build/NodeDRT.ofx.bundle    (GPLv3)"

if [ "${1:-}" = "install" ]; then
  DEST="/Library/OFX/Plugins"
  echo "Installing to $DEST (administrator password required)…"
  sudo mkdir -p "$DEST" && \
  sudo rm -rf "$DEST/NodeDRT.ofx.bundle" && \
  sudo cp -R build/NodeDRT.ofx.bundle "$DEST/" && \
  sudo xattr -dr com.apple.quarantine "$DEST/NodeDRT.ofx.bundle" 2>/dev/null
  echo "Installed. Restart DaVinci Resolve: the effect is under OpenFX > Node_One."
fi
echo "BUILD OK $TAG" >> "$LOG"
