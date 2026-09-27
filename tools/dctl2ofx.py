#!/usr/bin/env python3
# =============================================================================
#  NODE_ONE OFX — DCTL -> OFX generator
# -----------------------------------------------------------------------------
#  Reads each DCTL in dctl/ and the Inspector layout in tools/ui_layout.py and
#  writes gen/<key>.cpp containing:
#    * the DCTL code compiled as C++ (CPU path), in its own namespace
#    * the same DCTL code as Metal source (GPU path, compiled at runtime)
#    * the parameter / group tables that build the OFX Inspector
#  The DCTL math is never rewritten: only DEFINE_UI_PARAMS / DEFINE_UI_TOOLTIP
#  are lifted out, and transform() receives the parameter block.
#
#  Usage:  python3 tools/dctl2ofx.py        (run from the project root)
# =============================================================================
import os, re, sys, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import ui_layout

EMOJI_RE = re.compile(
    '[\U0001F000-\U0001FAFF\u2600-\u27BF\u2B00-\u2BFF\u2190-\u21FF\u2300-\u23FF'
    '\u2139\u2122\uFE0F\u200D\u20E3\u2194-\u2199\u2934\u2935\u3030\u303D\u3297\u3299]')


def die(msg):
    sys.stderr.write('dctl2ofx: error: ' + msg + '\n')
    sys.exit(1)


# ---------------------------------------------------------------------------
#  Lexing helpers
# ---------------------------------------------------------------------------
def strip_comments(s):
    """Remove // and /* */ comments, keep every newline (line numbers stay
    identical to the original .dctl) and keep string literals intact."""
    out = []
    i, n = 0, len(s)
    while i < n:
        if s.startswith('//', i):
            j = s.find('\n', i)
            i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append('\n' * s.count('\n', i, j))
            i = j
        elif s[i] == '"':
            j = i + 1
            while j < n and s[j] != '"' and s[j] != '\n':
                j += 2 if s[j] == '\\' else 1
            out.append(s[i:j + 1])
            i = j + 1
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def match_paren(s, i):
    """s[i] == '(' ; return index of the matching ')' (quotes aware)."""
    depth = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '"':
            j = i + 1
            while s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            i = j
        elif c in '({':
            depth += 1
        elif c in ')}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    die('unbalanced parenthesis')


def split_top(s):
    """Split on commas that are not inside {} () or quotes."""
    parts, depth, cur, i = [], 0, [], 0
    while i < len(s):
        c = s[i]
        if c == '"':
            j = i + 1
            while s[j] != '"':
                j += 2 if s[j] == '\\' else 1
            cur.append(s[i:j + 1])
            i = j + 1
            continue
        if c in '({':
            depth += 1
        elif c in ')}':
            depth -= 1
        if c == ',' and depth == 0:
            parts.append(''.join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
    parts.append(''.join(cur).strip())
    return parts


def unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return bytes(s[1:-1], 'utf-8').decode('unicode_escape').encode('latin-1').decode('utf-8')
    return s


def norm_label(s):
    s = EMOJI_RE.sub('', s)
    return re.sub(r'[\s_]+', ' ', s).strip().lower()


def clean_label(s):
    s = EMOJI_RE.sub('', s)
    s = s.replace('_', ' ')
    s = re.sub(r'\s+', ' ', s).strip()
    s = s.strip(':').strip()
    return s


def c_str(s):
    if s is None:
        return 'nullptr'
    b = s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    return '"' + b + '"'


def fnum(v):
    r = repr(float(v))
    return r


# ---------------------------------------------------------------------------
#  DCTL parsing
# ---------------------------------------------------------------------------
class UIParam:
    pass


def parse_dctl(path):
    raw = open(path, encoding='utf-8').read()
    code = strip_comments(raw)
    params, tooltips = [], {}
    out = []
    pos = 0
    for m in re.finditer(r'\b(DEFINE_UI_PARAMS|DEFINE_UI_TOOLTIP)\s*\(', code):
        if m.start() < pos:
            continue
        op = code.index('(', m.start())
        cp = match_paren(code, op)
        end = cp + 1
        # swallow a trailing ';' if any
        k = end
        while k < len(code) and code[k] in ' \t':
            k += 1
        if k < len(code) and code[k] == ';':
            end = k + 1
        out.append(code[pos:m.start()])
        out.append('\n' * code.count('\n', m.start(), end))
        args = split_top(code[op + 1:cp])
        if m.group(1) == 'DEFINE_UI_TOOLTIP':
            tooltips[norm_label(args[0])] = unquote(','.join(args[1:]).strip())
        else:
            p = UIParam()
            p.name, p.rawlabel, p.type = args[0], args[1], args[2]
            p.line = code.count('\n', 0, m.start()) + 1
            if p.type == 'DCTLUI_SLIDER_FLOAT' or p.type == 'DCTLUI_VALUE_BOX':
                p.kind = 'float'
                p.default, p.min, p.max, p.step = [float(x.rstrip('fF')) for x in args[3:7]]
            elif p.type == 'DCTLUI_SLIDER_INT':
                p.kind = 'float'  # exposed as float slider, passed as float
                die('DCTLUI_SLIDER_INT not supported yet (%s)' % p.name)
            elif p.type == 'DCTLUI_CHECK_BOX':
                p.kind = 'bool'
                p.default = float(int(args[3]))
                p.min, p.max, p.step = 0.0, 1.0, 1.0
            elif p.type == 'DCTLUI_COMBO_BOX':
                p.kind = 'choice'
                p.default = float(int(args[3]))
                p.enums = [e.strip() for e in args[4].strip()[1:-1].split(',')]
                p.options = [unquote(o) for o in split_top(args[5].strip()[1:-1])]
                if len(p.enums) != len(p.options):
                    die('%s: combo %s has %d enums and %d labels' % (path, p.name, len(p.enums), len(p.options)))
                p.min, p.max, p.step = 0.0, float(len(p.options) - 1), 1.0
            else:
                die('%s: unsupported UI type %s' % (path, p.type))
            params.append(p)
        pos = end
    out.append(code[pos:])
    body = ''.join(out)
    # '#line' directives from the original file would break our own #line mapping
    body = re.sub(r'(?m)^[ \t]*#line\b.*$', '', body)
    # A tooltip may be keyed either by the parameter's label (how OpenDRT writes
    # them) or by its variable name. Both forms are accepted; the label wins.
    used = set()
    for p in params:
        klabel, kname = norm_label(p.rawlabel), norm_label(p.name)
        p.tooltip = tooltips.get(klabel)
        if p.tooltip is not None:
            used.add(klabel)
        else:
            p.tooltip = tooltips.get(kname)
            if p.tooltip is not None:
                used.add(kname)
    # A tooltip whose key matches no parameter is a silent loss in the Inspector,
    # so say so rather than dropping it.
    for k in tooltips:
        if k not in used:
            sys.stderr.write('dctl2ofx: warning: %s: tooltip "%s" matches no parameter\n'
                             % (os.path.basename(path), k))
    return raw, body, params


def rewrite_transform(body, params):
    m = re.search(r'__DEVICE__\s+float3\s+transform\s*\(', body)
    if not m:
        die('transform() not found')
    op = body.index('(', m.start())
    cp = match_paren(body, op)
    args = body[op + 1:cp]
    texture = '__TEXTURE__' in args
    brace = body.index('{', cp)
    if body[cp + 1:brace].strip():
        die('unexpected tokens between transform() and its body')
    locals_ = []
    for p in params:
        t = 'float' if p.kind == 'float' else 'int'
        locals_.append('%s %s = P_.%s;' % (t, p.name, p.name))
    inj = ' '.join(locals_) + ' (void)0;'
    new = (body[:m.start()] + '__DEVICE__ float3 dctl_transform(__PARAMSREF__ DctlParams& P_, ' + args + ') {' + inj +
           body[brace + 1:])
    return new, texture


RENAMES = {
    # Metal builtin type names used as DCTL user identifiers
    'float3x3': 'dctl_float3x3', 'float2x2': 'dctl_float2x2', 'float4x4': 'dctl_float4x4',
}


def apply_renames(body):
    for a, b in RENAMES.items():
        body = re.sub(r'\b%s\b' % re.escape(a), b, body)
    return body


def params_block(params):
    enums, seen = [], set()
    for p in params:
        if p.kind == 'choice':
            names = [e for e in p.enums if e not in seen]
            seen.update(names)
            if names:
                enums.append('enum { %s };' % ', '.join(names))
    fields = ['    %s %s;' % ('float' if p.kind == 'float' else 'int', p.name) for p in params]
    return '\n'.join(enums) + '\nstruct DctlParams {\n' + '\n'.join(fields) + '\n};\n'


# ---------------------------------------------------------------------------
#  Code emission
# ---------------------------------------------------------------------------
def emit_metal(prelude, dctl_name, pblock, body, texture):
    if texture:
        call = 'dctl_transform(P, W, H, x, y, tr, tg, tb)'
        setup = ('    DctlTex tr = {src, D.rowFloatsSrc, W, H, 0, D.flipY};\n'
                 '    DctlTex tg = {src, D.rowFloatsSrc, W, H, 1, D.flipY};\n'
                 '    DctlTex tb = {src, D.rowFloatsSrc, W, H, 2, D.flipY};\n')
    else:
        call = 'dctl_transform(P, W, H, x, y, s[0], s[1], s[2])'
        setup = ''
    kernel = '''
#line 1 "node_one_kernel"
struct DctlDims { int width, height, rowFloatsSrc, rowFloatsDst, flipY, pad0, pad1, pad2; };
kernel void node_one_main(constant DctlParams& P [[buffer(0)]],
                          const device float* src [[buffer(1)]],
                          device float* dst [[buffer(2)]],
                          constant DctlDims& D [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]])
{
    const int W = D.width, H = D.height;
    if ((int)gid.x >= W || (int)gid.y >= H) return;
    const int x = (int)gid.x;
    const int row = (int)gid.y;
    const int y = D.flipY ? (H - 1 - row) : row;
%s    const device float* s = src + row * D.rowFloatsSrc + x * 4;
    device float* d = dst + row * D.rowFloatsDst + x * 4;
    const float3 o = %s;
    d[0] = o.x; d[1] = o.y; d[2] = o.z; d[3] = s[3];
}
''' % (setup, call)
    return (prelude + '\n#line 1 "node_one_params"\n' + pblock +
            '#line 1 "%s"\n' % dctl_name + body + '\n' + kernel)


def emit_cpu(ns, dctl_name, pblock, body, texture):
    if texture:
        setup = ('    const ::dctl::Tex tr = {src, srcRowFloats, W, H, 0, flipY};\n'
                 '    const ::dctl::Tex tg = {src, srcRowFloats, W, H, 1, flipY};\n'
                 '    const ::dctl::Tex tb = {src, srcRowFloats, W, H, 2, flipY};\n')
        call = 'dctl_transform(P, W, H, x, y, tr, tg, tb)'
    else:
        setup = ''
        call = 'dctl_transform(P, W, H, x, y, s[0], s[1], s[2])'
    return '''namespace %(ns)s {
using namespace ::dctl;
#line 1 "node_one_params"
%(pblock)s
#line 1 "%(dctl)s"
%(body)s
#line 1 "node_one_cpu"
static void cpu_render(const void* pv, const float* src, ptrdiff_t srcRowFloats,
                       float* dst, ptrdiff_t dstRowFloats,
                       int W, int H, int rowBegin, int rowEnd, int flipY)
{
    const DctlParams& P = *static_cast<const DctlParams*>(pv);
%(setup)s    for (int row = rowBegin; row < rowEnd; ++row) {
        const int y = flipY ? (H - 1 - row) : row;
        const float* s = src + row * srcRowFloats;
        float* d = dst + row * dstRowFloats;
        for (int x = 0; x < W; ++x, s += 4, d += 4) {
            const float3 o = %(call)s;
            d[0] = o.x; d[1] = o.y; d[2] = o.z; d[3] = s[3];
        }
    }
}
} // namespace %(ns)s
''' % dict(ns=ns, pblock=pblock, dctl=dctl_name, body=body, setup=setup, call=call)


def raw_string(s, tag='NODEONE'):
    # split in chunks: some compilers limit a single literal's length
    chunks = []
    step = 12000
    for i in range(0, len(s), step):
        chunks.append('R"%s(%s)%s"' % (tag, s[i:i + step], tag))
    return '\n'.join(chunks)


def write_if_changed(path, text):
    try:
        if open(path, encoding='utf-8').read() == text:
            return
    except OSError:
        pass
    open(path, 'w', encoding='utf-8').write(text)


def build_plugin(spec, prelude):
    key = spec['key']
    path = os.path.join(ROOT, 'dctl', spec['file'])
    raw, body, params = parse_dctl(path)
    body, texture = rewrite_transform(body, params)
    body = apply_renames(body)
    pblock = params_block(params)
    byname = {p.name: p for p in params}

    # ---- layout ------------------------------------------------------------
    groups = spec['groups']
    placed = {}
    synth = []
    ordered = []   # (param, groupIndex, label, hint, options)
    for gi, g in enumerate(groups):
        for item in g['params']:
            if isinstance(item, str):
                item = {'name': item}
            name = item['name']
            # SYNTHETIQUE : un parametre qui n'existe que dans le plugin, sans
            # contrepartie dans le DCTL - le bouton d'analyse de la balance des
            # blancs et le champ qui rend son score de confiance. Il n'a pas de
            # place dans le bloc de parametres du kernel, donc pas d'offset.
            if item.get('synth'):
                sp = UIParam()
                sp.name, sp.rawlabel = name, item.get('label', name)
                sp.kind = 'push' if item['synth'] == 'push' else 'float'
                sp.default = float(item.get('default', 0.0))
                sp.min = float(item.get('min', 0.0))
                sp.max = float(item.get('max', 100.0))
                sp.step = float(item.get('step', 0.1))
                sp.tooltip = item.get('hint')
                sp.synthetic = True
                ordered.append((sp, gi, item))
                continue
            if name not in byname:
                die('%s: layout names unknown parameter %s' % (key, name))
            if name in placed:
                die('%s: parameter %s placed twice' % (key, name))
            placed[name] = gi
            ordered.append((byname[name], gi, item))
    for name in spec.get('hidden', []):
        if name not in byname:
            die('%s: hidden names unknown parameter %s' % (key, name))
        placed[name] = -2
        ordered.append((byname[name], -2, {'name': name}))
    missing = [p.name for p in params if p.name not in placed]
    if missing:
        die('%s: parameters missing from layout: %s' % (key, ', '.join(missing)))

    # struct order == DCTL order; offsets computed from it
    offset = {p.name: 4 * i for i, p in enumerate(params)}

    lines = []
    opt_arrays = []
    for idx, (p, gi, item) in enumerate(ordered):
        label = item.get('label') or clean_label(p.rawlabel)
        hint = item.get('hint', p.tooltip)
        kind = 'nodeone::' + {'float': 'kParamFloat', 'bool': 'kParamBool',
                              'choice': 'kParamChoice', 'push': 'kParamPush'}[p.kind]
        poff = 'nodeone::kNoOffset' if getattr(p, 'synthetic', False) else str(offset[p.name])
        opts, nopts = 'nullptr', 0
        if p.kind == 'choice':
            options = item.get('options', p.options)
            if len(options) != len(p.options):
                die('%s: option override for %s has wrong length' % (key, p.name))
            an = 'kOpt_%s' % p.name
            opt_arrays.append('static const char* const %s[] = {%s};' % (an, ', '.join(c_str(o) for o in options)))
            opts, nopts = an, len(options)
        lines.append('    {%s, %s, %s, %s, %s, %s, %s, %s, %s, %d, %d, %s},' % (
            c_str(p.name), c_str(label), c_str(hint), kind, fnum(item.get('default', p.default)), fnum(p.min),
            fnum(p.max), fnum(p.step), opts, nopts, gi, poff))
    glines = ['    {%s, %s, %d},' % (c_str(g['name']), c_str(g['label']), 1 if g.get('open') else 0) for g in groups]
    about = spec.get('about', [])
    ns = 'nodeone_' + key
    metal_src = emit_metal(prelude, spec['file'], pblock, body, texture)

    cpp = []
    cpp.append('// GENERATED by tools/dctl2ofx.py from dctl/%s — do not edit.' % spec['file'])
    cpp.append('// Edit the DCTL or tools/ui_layout.py, then run: python3 tools/dctl2ofx.py')
    cpp.append('#include <cstddef>')
    cpp.append('#include "dctl_cpu.h"')
    cpp.append('#include "plugin_def.h"')
    cpp.append('#if defined(__clang__)')
    cpp.append('#pragma clang diagnostic ignored "-Wunused-function"')
    cpp.append('#pragma clang diagnostic ignored "-Wunused-variable"')
    cpp.append('#pragma clang diagnostic ignored "-Wunused-but-set-variable"')
    cpp.append('#pragma clang diagnostic ignored "-Wunused-const-variable"')
    cpp.append('#pragma clang diagnostic ignored "-Wmacro-redefined"')
    cpp.append('#elif defined(__GNUC__)')
    cpp.append('#pragma GCC diagnostic ignored "-Wunused-function"')
    cpp.append('#pragma GCC diagnostic ignored "-Wunused-variable"')
    cpp.append('#pragma GCC diagnostic ignored "-Wunused-but-set-variable"')
    cpp.append('#endif')
    cpp.append(emit_cpu(ns, spec['file'], pblock, body, texture))
    cpp.append('#line %d "gen/%s.cpp"' % (len('\n'.join(cpp).split('\n')) + 2, key))
    cpp.append('namespace %s {' % ns)
    cpp.append('static const char* const kMetalSource =\n%s;' % raw_string(metal_src))
    cpp.extend(opt_arrays)
    cpp.append('static const nodeone::GroupSpec kGroups[] = {\n%s\n    {nullptr, nullptr, 0}\n};' % '\n'.join(glines))
    cpp.append('static const nodeone::ParamSpec kParams[] = {\n%s\n};' % '\n'.join(lines))
    cpp.append('static const char* const kAbout[] = {%s nullptr};' % ''.join(c_str(a) + ', ' for a in about))
    # The plugin writes each slider at ParamSpec::offset. Prove that every one
    # of those offsets is really that field, so a reordered or retyped DCTL
    # parameter can never silently drive the wrong control.
    cpp.append('static_assert(sizeof(DctlParams) == %d, "parameter block size");' % (4 * len(params)))
    for p in params:
        cpp.append('static_assert(offsetof(DctlParams, %s) == %d, "offset of %s");' % (p.name, offset[p.name], p.name))
        ctype = 'float' if p.kind == 'float' else 'int'
        cpp.append('static_assert(sizeof(DctlParams::%s) == 4 && ::dctl::is_same<decltype(DctlParams::%s), %s>::value,'
                   ' "type of %s");' % (p.name, p.name, ctype, p.name))
    cpp.append('} // namespace %s' % ns)
    cpp.append('namespace nodeone {')
    cpp.append('extern const PluginDef kPlugin_%s;' % key)
    cpp.append('const PluginDef kPlugin_%s = {' % key)
    cpp.append('    %s, %s, %s,' % (c_str(spec['id']), c_str(spec['label']), c_str(ui_layout.GROUPING)))
    cpp.append('    %s,' % c_str(spec['description']))
    cpp.append('    %d, %d,' % tuple(spec['version']))
    cpp.append('    %s::kGroups, %d,' % (ns, len(groups)))
    cpp.append('    %s::kParams, %d,' % (ns, len(ordered)))
    cpp.append('    sizeof(%s::DctlParams),' % ns)
    cpp.append('    %s::kMetalSource, "node_one_main",' % ns)
    cpp.append('    &%s::cpu_render,' % ns)
    cpp.append('    %d,' % (1 if texture else 0))
    cpp.append('    %s::kAbout, %d,' % (ns, len(about)))
    lut = spec.get('lut')
    if lut:
        if lut['param'] not in byname:
            die('%s: lut names unknown parameter %s' % (key, lut['param']))
        cpp.append('    %s, %d, %s' % (c_str(lut['param']), int(lut['value']), c_str(lut.get('group'))))
    else:
        cpp.append('    nullptr, 0, nullptr')
    cpp.append('};')
    cpp.append('} // namespace nodeone')
    write_if_changed(os.path.join(ROOT, 'gen', key + '.cpp'), '\n'.join(cpp) + '\n')
    # plain Metal source too, for tools/metal_check
    write_if_changed(os.path.join(ROOT, 'gen', key + '.metal'), metal_src)
    return dict(key=key, params=len(params), visible=len([o for o in ordered if o[1] != -2]), texture=texture)


def bake_lut_kernel():
    """One source of truth for the LUT kernel: src/core/NodeOneLut.metal is
    baked into a C++ string for the plugin and copied to gen/ so the build's
    kernel check compiles it on the real GPU like the generated ones."""
    src = open(os.path.join(ROOT, 'src', 'core', 'NodeOneLut.metal'), encoding='utf-8').read()
    write_if_changed(os.path.join(ROOT, 'gen', 'lut.metal'), src)
    header = ('// GENERATED from src/core/NodeOneLut.metal by tools/dctl2ofx.py — do not edit.\n'
              '#pragma once\nstatic const char* const kLutMetalSource =\n%s;\n' % raw_string(src, 'NODEONELUT'))
    write_if_changed(os.path.join(ROOT, 'gen', 'lut_metal_src.h'), header)
    return len(src)
def main():
    prelude = open(os.path.join(ROOT, 'src', 'core', 'dctl_metal_prelude.metal'), encoding='utf-8').read()
    os.makedirs(os.path.join(ROOT, 'gen'), exist_ok=True)
    bake_lut_kernel()
    only = sys.argv[1:]
    for spec in ui_layout.PLUGINS:
        if only and spec['key'] not in only:
            continue
        r = build_plugin(spec, prelude)
        print('  %-12s %2d params (%2d in Inspector)  %s' % (r['key'], r['params'], r['visible'],
                                                           'spatial' if r['texture'] else 'per-pixel'))


if __name__ == '__main__':
    main()
