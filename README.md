# Node DRT

A display rendering transform for DaVinci Resolve on macOS, built as an OpenFX
plugin. Free software under the **GNU General Public License, version 3 or
later** — all of it, not part of it.

This repository is the **complete corresponding source** for the
`NodeDRT.ofx.bundle` that is distributed. Nothing has been left out: what is
here builds the binary that ships, with the same compiler flags.

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
everything downstream of it, this plugin included. That is not a technicality
worked around here — it is the condition OpenDRT was given away under, and it
travels on.

**The rendering itself is his work.** The tonescale, the rendering space, the
purity compression, the brilliance and the hue modules come from OpenDRT. He is
not responsible for the changes made here, and this project is not affiliated
with him. <https://github.com/jedypod/open-display-transform>

---

## Building

macOS, Xcode Command Line Tools (`xcode-select --install`). Python 3 optional.

```sh
./build.sh            # build build/NodeDRT.ofx.bundle
./build.sh install    # ...and copy it to /Library/OFX/Plugins
./build.sh clean
```

Restart Resolve. The effect appears under **OpenFX > Node_One > Node DRT**.

`make` alone works too. The build is universal (arm64 + x86_64) and falls back
to this Mac's architecture if the other SDK slice is missing.

---

## What is where

| Path | What it is |
|---|---|
| `dctl/NODE_DRT.dctl` | **the transform itself** — the single source of truth |
| `tools/dctl2ofx.py` | turns the DCTL into `gen/drt.cpp` (CPU) and `gen/drt.metal` (GPU) |
| `tools/ui_layout.py` | the Inspector layout, group order and tooltips |
| `gen/` | generated; derived from the DCTL, never edited by hand |
| `src/core/` | the OFX plugin layer: parameters, render, Metal backend, LUT stage |
| `src/bundle_drt_main.cpp` | plugin registration |
| `openfx/` | the OpenFX headers and support library (ASWF, BSD 3-Clause), vendored |
| `licenses/` | every licence and attribution that applies |

**Edit the DCTL, not `gen/`.** One file describes the transform; the CPU and GPU
paths are generated from it, so they cannot disagree — a whole class of bug that
simply does not exist here.

---

## The plugin

59 controls in seven groups, in the order the picture is processed: Input /
Output, White, Look / Toning / Tone, Color, Trims, Skin, Scopes. Groups are
split into collapsible sub-sections, each with its own bypass, and every
creative group has a one-click Reset.

- **Seven film looks**, each a set of parameter values fitted numerically
  against a spectral simulation of one negative stock printed on one print
  stock, measured over several thousand colours - refitted on 9 October 2026
  with the current engine, under constraints that hold 18% grey exactly and
  forbid any gradient, neutral, coloured or neon, from stepping backwards.
- **Sixteen input gamuts** and **ten log curves**.
- **SDR and HDR** output: Rec.1886, sRGB, Display P3, Rec.2100 PQ and HLG.
- 18 % grey lands at the same level on all eight looks, so changing look does
  not move your camera exposure.
- **Skin**, its own section: Skin Line pulls skin onto the vectorscope skin
  tone line (the line Skin Check reads) with luminance held exactly; Skin
  Saturation doses skin colour with the subtractive saturation model.
  Highlights, Midtones and Shadows relight the face zone by zone, each up to
  one stop; Zone Pivot places the three zones on the face you are grading,
  Mask Softness sets how gradually the skin mask ends, and Show Zones paints
  the zones with a legend of their limits in stops. The three lights are
  exposures on scene light, before the curve, so a brightened highlight rolls
  into the look's shoulder instead of clipping, and they are monotone whatever
  the settings: a gradient across a face never steps backwards. Skin is found
  on the scene colour, so the selection does not move when the exposure
  changes.
- **Look Intensity** is exactly linear: between 0 and 1 the picture is
  rendered with the full look and with Default and the two outputs are mixed,
  so 0.50 is precisely half way, pixel by pixel. In between, rendering costs
  twice as much; at 0 and 1 it costs the same as before.
- **Tonescale Intensity**: doses the curve picked in the Tonescale menu against
  the look's own curve by mixing the outputs of the two curves, so it is
  linear too.
- **No control breaks the picture** (audit of 26 October 2026). Every slider
  was swept across its whole range on real footage and on dense colour ramps:
  no NaN, no gradient that steps backwards, no isolated kink.
  - The skin mask (Skin Line, Skin Saturation, Skin Light) is **smoothed in
    the image**, like a professional qualifier: each pixel averages the mask
    over 17 samples (radius = height/360, so the same size at any
    resolution), weighted by scene-luminance similarity so it follows the
    edges of the picture. Grain, pores and blemishes no longer get a dose
    different from their neighbours. Its hue window is centred on skin as it
    is in the SCENE (measured on nine S-Log3 faces), where it is evaluated.
  - Skin Line turns hue with a Gaussian profile: monotone for any setting,
    no fold, no corner.
  - Highlight Density is monotone by construction (it used to step backwards
    above 0.7); Highlight Purity, negative Log Contrast and the OpenDRT
    purity-compression limit no longer have an infinite slope or a corner;
    Chroma, Mid Purity, Shadows and Highlight Saturation no longer change
    slope where two channels cross or where a scale reaches zero.
  - With every control at rest the render matches the previous build to
    within 0.5/255 (most pixels to the bit).
- **About 2.4 times faster on the GPU** (26 October 2026): pow, exp, log and
  the cube root use the GPU's fast functions (exact IEEE handling kept for
  zero, negatives and NaN; sin, cos and atan2 stay precise), the skin mask
  uses constant sample directions and a polynomial atan2. Measured on 4K and
  HD frames over every group of controls: 2.0 to 2.8 times faster, at most
  0.13/255 from the previous build, never a non-finite value. The effect
  accepts reduced render scales again (viewer, proxies), so Resolve no longer
  has to compute it at full resolution.

---

## Attribution

Read `licenses/NOTICE-NodeDRT.txt` first — it is the short version of all of
this, and it ships inside the bundle.

- **OpenDRT v1.0.1, Jed Smith, GPLv3** — the rendering engine.
- **Film look presets** fitted against [spektrafilm](https://github.com/andreavolpato/spektrafilm)
  references by Andrea Volpato, CC BY-SA 4.0. **No LUT data is embedded**: what
  remains are fitted parameter values belonging to this transform.
- **Oklab** (Bjorn Ottosson, public domain / MIT) — the colour space Skin Line
  turns hue in, written here from the published formulas.
- **Subtractive saturation** — Nikita Petrovich, MIT.
- **OpenFX support library** — Academy Software Foundation, BSD 3-Clause.
- **Film stock names** are trademarks of their owners, used descriptively. See
  `licenses/TRADEMARKS.txt`.

---

## Your rights

Use, study, modify and redistribute it, including commercially and including
free of charge. The conditions are that anyone you give a binary to can obtain
this source under the same licence, and that the notices travel with it.

If you received a compiled `NodeDRT.ofx.bundle` and want the source, you are
looking at it. It is also the source referred to by the written offer inside the
bundle, in `Contents/Resources/NOTICE-NodeDRT.txt`.

---

Copyright © Samuel Drouin. Licensed under the GNU General Public License v3 or
later — see `LICENSE`. Distributed in the hope that it will be useful, but
**without any warranty**.
