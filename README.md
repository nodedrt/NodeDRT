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

46 controls in nine groups: Input, Display, Look, Toning, Tone, Trims, White,
Color, Scopes.

- **Seven film looks**, each a set of parameter values fitted numerically
  against a spectral simulation of one negative stock printed on one print
  stock, measured over several thousand colours.
- **Sixteen input gamuts** and **ten log curves**.
- **SDR and HDR** output: Rec.1886, sRGB, Display P3, Rec.2100 PQ and HLG.
- 18 % grey lands at the same level on all eight looks, so changing look does
  not move your camera exposure.
- Every bypass returns to the resting state to the bit.

---

## Attribution

Read `licenses/NOTICE-NodeDRT.txt` first — it is the short version of all of
this, and it ships inside the bundle.

- **OpenDRT v1.0.1, Jed Smith, GPLv3** — the rendering engine.
- **Film look presets** fitted against [spektrafilm](https://github.com/andreavolpato/spektrafilm)
  references by Andrea Volpato, CC BY-SA 4.0. **No LUT data is embedded**: what
  remains are fitted parameter values belonging to this transform.
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
