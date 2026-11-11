#!/usr/bin/env python3
"""Profiling aid: copies of gen/drt.metal where parameters are compile-time
constants (their defaults, or name=value overrides), to measure what kernel
specialisation would gain.  profile_consts.py OUT MODE [name=value ...]
MODE: ints = combos + checkboxes constant ; all = every parameter constant"""
import sys, os, re
sys.path.insert(0, 'tools')
import dctl2ofx
out, mode = sys.argv[1], sys.argv[2]
over = dict(a.split('=') for a in sys.argv[3:] if not a.startswith('bake='))
bake = sum([a[5:].split(',') for a in sys.argv[3:] if a.startswith('bake=')], [])
_, _, params = dctl2ofx.parse_dctl('dctl/NODE_DRT.dctl')
src = open('gen/drt.metal').read()
n = 0
for p in params:
    if mode == 'ints' and p.kind == 'float':
        continue
    if mode == 'neutral' and p.kind == 'float' and float(over.get(p.name, p.default)) not in (0.0, 1.0):
        continue
    if mode == 'zero' and p.kind == 'float' and float(over.get(p.name, p.default)) != 0.0 and p.name not in bake:
        continue
    v = over.get(p.name, p.default)
    if p.kind == 'float':
        lit = repr(float(v)) + 'f'
        pat = 'float %s = P_.%s;' % (p.name, p.name)
        rep = 'float %s = %s;' % (p.name, lit)
    else:
        lit = str(int(float(v)))
        pat = 'int %s = P_.%s;' % (p.name, p.name)
        rep = 'int %s = %s;' % (p.name, lit)
    if pat in src:
        src = src.replace(pat, rep); n += 1
open(out, 'w').write(src)
print(out, n, 'constants')
