# Node DRT v2

**A film-look display rendering transform (DRT) for DaVinci Resolve Studio on
macOS**, built as an OpenFX plugin. One node at the end of your tree turns
camera log into a finished, screen-ready image.

**Get the built, signed plugin:** <https://node-drt.lemonsqueezy.com>

Free software under the **GNU General Public License, version 3 or later** —
all of it, not part of it. This repository is the **complete corresponding
source** of the `NodeDRT2.ofx.bundle` that is distributed: what is here builds
the binary that ships, with the same compiler flags.

---

## Where it comes from

```
OpenDRT v1.0.1 — Jed Smith — GPLv3
        │
        ▼
NODE_DRT.dctl — Samuel Drouin — a modified version of OpenDRT
        │
        ▼
Node DRT — this OpenFX plugin, built from that DCTL
```

Because the middle step modifies Jed Smith's work, his licence covers
everything downstream of it, this plugin included. That is the condition
OpenDRT was given away under, and it travels on.

**The rendering itself is his work.** The tonescale, the rendering space, the
purity compression, the brilliance and the hue modules come from OpenDRT. He is
not responsible for the changes made here, and this project is not affiliated
with him. <https://github.com/jedypod/open-display-transform>

---

## What it does

- **Input**: 16 camera gamuts and 10 log curves (Sony, ARRI, RED, Panasonic,
  Fujifilm, Blackmagic, ACES…). **Output**: Rec.709, sRGB, Display P3, HDR PQ
  and HLG. 18 % grey lands at the same level on every look.
- **Seven film looks**, parameter sets fitted against spectral simulations of
  negative and print stocks (spektrafilm). In v2 their curves have a continuous
  shoulder into white, more contrast at grey and denser blacks.
- **Color**: chroma, path to white, subtractive saturation, colour density.
- **Density**: print-style density by zone (shadows, midtones, highlights) and
  by colour (six hues). The selection is a field blurred in the picture, like a
  qualifier, and re-weighted by each pixel's own colour, so edges never step
  and neutrals never move. Smart Show Zones / Show Colors views.
- **Trims**: Log Contrast, Overlay, Black Lift and White Roll-Off with their
  pivots, Shadows; Highlights (purity, density, saturation, brilliance); Mid
  Purity. Curve View draws the curve over the picture.
- **Skin**: a qualifier-style skin matte (hue centre and width, saturation
  limits, shadows reach, softness, edge blur, Show Mask), Skin Line, Skin
  Saturation, and zone-by-zone face lighting.
- **Grain**: film grain for 65, 35, 16 and 8mm as seen on a 4K scan.
- **Instruments**: False Color (stops), Skin Check, Curve View.
- **Never breaks the picture**: every control is swept across its range on
  ramps and footage — no NaN, no gradient stepping backwards, no colour specks
  in the blacks. GPU and CPU agree to under 0.1 of a 10-bit code value.

Metal on Apple Silicon and Intel (universal binary). macOS 11+, DaVinci
Resolve **Studio** 18+ (the free Resolve does not load OpenFX plugins).
Node DRT v2 has its own plugin identifier and installs **next to** Node DRT 1.x.

---

## Building

macOS, Xcode Command Line Tools (`xcode-select --install`), Python 3.

```sh
./build.sh            # build build/NodeDRT2.ofx.bundle
./build.sh install    # ...and copy it to /Library/OFX/Plugins (asks for your password)
./build.sh clean
```

Restart Resolve. The effect appears under **OpenFX > Node_One > Node DRT v2**.

---

## What is where

| Path | What it is |
|---|---|
| `dctl/NODE_DRT.dctl` | **the transform itself** — the single source of truth |
| `tools/dctl2ofx.py` | turns the DCTL into `gen/drt.cpp` (CPU) and `gen/drt.metal` (GPU) |
| `tools/ui_layout.py` | the Inspector layout, group order and tooltips |
| `gen/` | generated; derived from the DCTL, never edited by hand |
| `src/core/NodeOnePlugin.cpp` | the OFX layer: parameters, render, smart views, resets |
| `src/core/NodeOneMetal.mm` | the Metal backend: specialised kernels, skin pre-pass, stages |
| `src/core/NodeDensity*` | the Density stage: shared maths, CPU path, Metal kernels |
| `src/core/NodeTexture*` | the Grain stage: shared maths, CPU path, Metal kernels |
| `tests/` | GPU vs CPU checks (`gpu_cpu_test.mm`, `density_gpu_test.mm`, `texture_gpu_test.mm`) and benchmarks |
| `openfx/` | the OpenFX headers and support library (ASWF, BSD 3-Clause), vendored |
| `licenses/` | every licence and attribution that applies, and `CHANGELOG.txt` |

**Edit the DCTL, not `gen/`.** The CPU and GPU paths are generated from one
file, so they cannot disagree.

---

## Attribution

Read `licenses/NOTICE-NodeDRT.txt` first — it is the short version of all of
this, and it ships inside the bundle.

- **OpenDRT v1.0.1, Jed Smith, GPLv3** — the rendering engine.
- **Film look presets** fitted against [spektrafilm](https://github.com/andreavolpato/spektrafilm)
  references by Andrea Volpato, CC BY-SA 4.0. **No LUT data is embedded.**
- **Grain**: strengths and gauge ratios measured on spektrafilm's grain model;
  overall level from Kodak's published RMS granularity.
- **Density**: from RELIEF, by the same author, same licence.
- **Oklab** (Bjorn Ottosson, public domain / MIT), written from the published
  formulas.
- **Subtractive saturation** — Nikita Petrovich, MIT.
- **OpenFX support library** — Academy Software Foundation, BSD 3-Clause.
- **Film stock names** are trademarks of their owners, used descriptively. See
  `licenses/TRADEMARKS.txt`.

---

## Your rights

Use, study, modify and redistribute it, including commercially. The conditions
are that anyone you give a binary to can obtain this source under the same
licence, and that the notices travel with it.

If you received a compiled `NodeDRT2.ofx.bundle` and want the source, you are
looking at it. It is also the source referred to by the written offer inside the
bundle, in `Contents/Resources/NOTICE-NodeDRT.txt`.

---

Copyright © Samuel Drouin. Licensed under the GNU General Public License v3 or
later — see `LICENSE`. Distributed in the hope that it will be useful, but
**without any warranty**.
