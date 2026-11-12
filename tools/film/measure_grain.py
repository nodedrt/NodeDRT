# Measures spektrafilm's grain (per gauge, UHD pixel pitch) for NodeTextureMath.h. Needs spektrafilm on the path.
exec(open(__file__.replace('measure_grain.py','measure_grain_common.py')).read().split("S = 384")[0])
import json
S = 512
D = [0.10, 0.20, 0.28, 0.336, 0.40, 0.48, 0.56, 0.64, 0.72]
res = {}
for F in [8.0, 16.0, 35.0, 65.0]:
    Sg, Sd = sim(F * S / 3840.0, True), sim(F * S / 3840.0, False)
    sig = []; corr = np.zeros((3, 3)); psd = np.zeros((S, S)); dens = []
    for d in D:
        img = np.full((S, S, 3), di2lin(d))
        g = np.asarray(Sg.process(img), float); c = np.asarray(Sd.process(img), float)
        n = (g - c)[8:-8, 8:-8]
        # density slope per DI step, to express the grain in DI code
        cp = np.asarray(Sd.process(np.full((4, 4, 3), di2lin(d + 0.01))), float).mean((0, 1))
        cm = np.asarray(Sd.process(np.full((4, 4, 3), di2lin(d - 0.01))), float).mean((0, 1))
        slope = (cp - cm) / 0.02
        sdi = n.std((0, 1)) / slope
        sig.append(sdi.tolist()); dens.append(c.mean((0, 1)).tolist())
        z = (n - n.mean((0, 1))) / n.std((0, 1))
        corr += np.corrcoef(z.reshape(-1, 3).T) / len(D)
        for k in range(3):
            P = np.abs(np.fft.fft2(z[..., k], s=(S, S))) ** 2
            psd += P
    psd /= psd.sum()
    # radial kernel = IFFT(sqrt(PSD)) (zero phase), centre row = separable 1-D estimate
    K = np.real(np.fft.ifft2(np.sqrt(psd))); K = np.fft.fftshift(K)
    row = K[S // 2, S // 2 - 8: S // 2 + 9]; col = K[S // 2 - 8: S // 2 + 9, S // 2]
    k1 = (row + col) / 2; k1 = k1 / np.sqrt((k1 ** 2).sum())
    res[F] = dict(sig=sig, corr=corr.tolist(), k1=k1.tolist(), dens=dens)
    print(F, 'sig@0.336', np.round(sig[3], 4), 'corr', np.round(corr[0, 1], 2), np.round(corr[0, 2], 2), np.round(corr[1, 2], 2), 'k1', np.round(k1[6:11], 3), flush=True)
json.dump(res, open('grain_meas.json', 'w'))
