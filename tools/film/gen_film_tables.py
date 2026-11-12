# Node DRT 1.3 - film print tables (negative -> print, computed by spektrafilm).
# One 65^3 table per look: DaVinci Intermediate code (0..1, DaVinci Wide Gamut)
# -> display-linear Rec.709, paper white = 1, stored as logits of (v+0.02)/1.04
# (like Origine's print stage: toe and shoulder stay sharp between grid points).
# Usage: SPEKTRAFILM_SRC=/path/to/spektrafilm/src python3 tools/film/gen_film_tables.py resources/film/film_tables.bin
# File: "NDFILM01", int32 N, int32 count, then count x N^3 x 3 float16,
# index ((r*N + g)*N + b)*3 + c.
import struct
# Planches avant/apres : looks Node DRT actuels vs nouveaux tirages calcules par
# spektrafilm (moteur negatif -> tirage), sur les images de Samuel (Canon R8,
# C-Log3 / Cinema Gamut -> DaVinci Wide Gamut / Intermediate, comme sa timeline).
import sys, os, numpy as np
sys.path.insert(0, os.environ.get('SPEKTRAFILM_SRC', 'spektrafilm/src'))
import warnings; warnings.filterwarnings('ignore')
import colour
from spektrafilm import init_params
from spektrafilm.runtime.params_builder import digest_params
from spektrafilm.runtime.process import Simulator

DI_A, DI_B, DI_C, DI_M = 0.0075, 7.0, 0.07329248, 10.44426855
def di2lin(x): return np.where(x <= 0.02740668, x / DI_M, np.exp2(x / DI_C - DI_B) - DI_A)
def lin2di(x): return np.where(x <= 0.00262409, x * DI_M, (np.log2(np.maximum(x, 1e-9) + DI_A) + DI_B) * DI_C)

def simulator(film, prt, pe=None, gamma=1.0, dir_amt=1.0, glare=None, ys=0.0, ms=0.0, spatial=False):
    p = init_params(film, prt)
    p.debug.deactivate_spatial_effects = not spatial; p.debug.deactivate_stochastic_effects = True
    p.film_render.halation.active = False; p.film_render.grain.active = False
    p.camera.auto_exposure = False; p.camera.exposure_compensation_ev = 0.0
    p.io.input_color_space = 'DaVinci Wide Gamut'; p.io.input_cctf_decoding = False
    p.io.output_color_space = 'sRGB'; p.io.output_cctf_encoding = False
    p.film_render.density_curve_gamma = gamma
    p.film_render.dir_couplers.amount = dir_amt
    if glare is not None: p.print_render.glare.percent = glare
    if pe is not None: p.enlarger.print_exposure = float(pe)
    p.enlarger.y_filter_shift = float(ys); p.enlarger.m_filter_shift = float(ms)
    return Simulator(digest_params(p))
def run(S, lin): return np.asarray(S.process(np.asarray(lin, float).reshape(1, -1, 3).copy()))[0].reshape(np.shape(lin))

GREY = 0.1110
def film_look(film, prt, white='stretch', grey=GREY, spatial=False, clean_hl=0.0, **kw):
    # darkroom choice: print exposure so that grey lands at `grey`.
    #  white='stretch': print white of DI 0.99 scaled to display 1 (the method of the 7 references)
    #  white='paper'  : the paper itself is display white (each channel, so paper = neutral white):
    #                   highlights roll off into the paper like a real print, nothing is stretched;
    #                   then the printer lights (Y / M filters) are set so that grey prints neutral.
    g, w = np.array([[0.18] * 3]), di2lin(np.array([[0.99] * 3]))
    paper = np.array([[0.18 * 2.0 ** 12] * 3])
    ys = ms = 0.0
    def solve_pe(ys, ms):
        lo, hi = 0.3, 4.0
        for _ in range(22):
            m = 0.5 * (lo + hi); S = simulator(film, prt, m, ys=ys, ms=ms, **kw)
            if white == 'stretch': ratio = run(S, w).max() * grey / run(S, g).mean()
            else: ratio = grey / (run(S, g) / run(S, paper)).mean()     # grey relative to paper
            if ratio < 1.0: lo = m
            else: hi = m
        return 0.5 * (lo + hi)
    pe = solve_pe(ys, ms)
    if white == 'paper':
        for _ in range(3):   # grey neutral relative to paper white: Newton on (Y, M) filter shifts
            def err(y, m):
                S = simulator(film, prt, pe, ys=y, ms=m, **kw); q = (run(S, g) / run(S, paper))[0]
                return np.log2(np.array([q[0] / q[1], q[2] / q[1]]))
            e0 = err(ys, ms); J = np.stack([(err(ys + 2, ms) - e0) / 2, (err(ys, ms + 2) - e0) / 2], 1)
            d = np.linalg.solve(J, -e0); ys += d[0]; ms += d[1]
            pe = solve_pe(ys, ms)
    S = simulator(film, prt, pe, ys=ys, ms=ms, **kw)
    S2 = simulator(film, prt, pe, ys=ys, ms=ms, spatial=spatial, **kw) if spatial else S
    if white == 'stretch':
        gain = grey / run(S, g).mean()
        return lambda dwg: np.clip(run(S, dwg) * gain, 0, 1) ** (1 / 2.4)
    pw = run(S, paper)[0]
    def render(dwg):
        o = (np.asarray(S2.process(np.asarray(dwg, float).copy())) if spatial else run(S, dwg)) / pw
        if clean_hl > 0:
            # highlights fade into the paper white, neutral: no colour cast from the
            # layer cross-over right at the top of the print curve
            Y = o @ np.array([0.2126, 0.7152, 0.0722])
            w = clean_hl * np.clip((o.max(-1) - 0.70) / 0.30, 0, 1) ** 2
            o = o + w[..., None] * (Y[..., None] - o)
        return np.clip(o, 0, 1) ** (1 / 2.4)
    return render

N = 65
looks = [('kodak_vision3_250d', 'kodak_2383'), ('kodak_vision3_500t', 'kodak_2383'), ('kodak_vision3_250d', 'kodak_2393'),
         ('kodak_portra_400', 'kodak_portra_endura'), ('kodak_ektar_100', 'kodak_ultra_endura'),
         ('fujifilm_pro_400h', 'fujifilm_crystal_archive_typeii'), ('kodak_gold_200', 'kodak_supra_endura')]
STYLE = dict(gamma=1.06, dir_amt=1.15, glare=0.02, white='paper', grey=0.1114)
g = np.linspace(0, 1, N)
cube = np.stack(np.meshgrid(g, g, g, indexing='ij'), -1).reshape(-1, 3)
out = [b'NDFILM01', struct.pack('<ii', N, len(looks))]
for film, prt in looks:
    f = film_look(film, prt, **STYLE)              # returns display code (^1/2.4); undo below
    v = f(di2lin(cube)) ** 2.4                     # clip 0..1 inside; display linear
    # highlights fade neutral into the paper white (clean_hl 0.6), same as the planches
    Y = v @ np.array([0.2126, 0.7152, 0.0722]); w = 0.6 * np.clip((v.max(-1) - 0.70) / 0.30, 0, 1) ** 2
    v = v + w[:, None] * (Y[:, None] - v)
    y = np.clip((v + 0.02) / 1.04, 1e-4, 1 - 1e-4)
    q = np.log(y / (1 - y)).astype(np.float16)
    out.append(q.tobytes())
    gi = np.argmin(abs(cube - 0.336043).sum(1)); print(film, prt, 'grey ->', v[gi].round(4), flush=True)
open(sys.argv[1] if len(sys.argv) > 1 else 'resources/film/film_tables.bin', 'wb').write(b''.join(out))
print('bytes', sum(len(o) for o in out))
