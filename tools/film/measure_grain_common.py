import sys, numpy as np, warnings; warnings.filterwarnings('ignore')
sys.path.insert(0, '/tmp/spektrafilm/src'); sys.path.insert(0, '/tmp/stubs')
from spektrafilm import init_params
from spektrafilm.runtime.params_builder import digest_params
from spektrafilm.runtime.process import Simulator
DI_A, DI_B, DI_C, DI_M = 0.0075, 7.0, 0.07329248, 10.44426855
def di2lin(x): return np.where(x <= 0.02740668, x / DI_M, np.exp2(x / DI_C - DI_B) - DI_A)
def sim(fmt, grain=True):
    p = init_params('kodak_vision3_250d', 'kodak_2383')
    p.debug.deactivate_spatial_effects = False; p.debug.deactivate_stochastic_effects = not grain
    p.film_render.halation.active = False; p.film_render.glare.active = False; p.print_render.glare.active = False
    p.film_render.dir_couplers.diffusion_size_um = 0.0 if False else p.film_render.dir_couplers.diffusion_size_um
    p.film_render.grain.active = grain
    p.camera.auto_exposure = False; p.camera.exposure_compensation_ev = 0.0; p.camera.film_format_mm = fmt
    p.io.input_color_space = 'DaVinci Wide Gamut'; p.io.input_cctf_decoding = False
    p.io.output_color_space = 'sRGB'; p.io.output_cctf_encoding = False
    p.taps.inject = 'rgb_in'; p.taps.collect = 'cmy_film'
    return Simulator(digest_params(p))
S = 384
import time
t=time.time()
for fmt in [35.0]:
    Sg, Sd = sim(fmt, True), sim(fmt, False)
    for d in [0.2, 0.336, 0.5]:
        img = np.full((S, S*16//9 if False else S, 3), di2lin(d))
        g = np.asarray(Sg.process(img)); c = np.asarray(Sd.process(img))
        n = g - c
        print(fmt, d, 'density', c.mean((0,1)).round(3), 'grain std', n.std((0,1)).round(4), '%.1fs' % (time.time()-t), flush=True)
