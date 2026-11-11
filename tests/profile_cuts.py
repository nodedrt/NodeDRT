#!/usr/bin/env python3
"""Profiling aid: writes copies of gen/drt.metal that stop transform() early
(return rgb;) at given DCTL line numbers, so the cost of each section can be
read off the difference in kernel time. Usage: profile_cuts.py LINE [LINE...]"""
import sys, os
src = open('gen/drt.metal').read().split('\n')
mark = next(i for i, l in enumerate(src) if l.startswith('#line 1 "NODE_DRT.dctl"'))
os.makedirs('build/prof', exist_ok=True)
for a in sys.argv[1:]:
    ln = int(a)
    out = list(src)
    idx = mark + ln          # metal line index of DCTL line ln (1-based -> mark+ln)
    out[idx] = '  return rgb; ' + out[idx]
    open('build/prof/cut_%d.metal' % ln, 'w').write('\n'.join(out))
    print('build/prof/cut_%d.metal' % ln)
