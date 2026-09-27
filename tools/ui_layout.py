# =============================================================================
#  NODE_ONE OFX — Inspector layout
# -----------------------------------------------------------------------------
#  One entry per DCTL. Every DEFINE_UI_PARAMS must appear exactly once, either
#  in a group or in "hidden" (hidden = informational DCTL entries such as
#  section headers or credit menus: fixed at their default, not shown).
#
#  Param entries are either the DCTL identifier, or a dict:
#     {'name': id, 'label': 'Inspector label', 'hint': 'tooltip',
#      'options': [...same length as the DCTL combo...]}
#  Without 'label' the DCTL label is used, cleaned of emojis and underscores.
#  Without 'hint' the DCTL DEFINE_UI_TOOLTIP is used when it exists.
#
#  The OFX parameter name is always the DCTL identifier: never rename one, or
#  saved grades will lose that slider's value.
# =============================================================================

GROUPING = 'Node_One'

WORKFLOW = 'Workflow: DaVinci YRGB (not Color Managed), timeline DaVinci Wide Gamut / Intermediate.'


def P(name, label=None, hint=None, **kw):
    d = {'name': name}
    if label:
        d['label'] = label
    if hint:
        d['hint'] = hint
    d.update(kw)
    return d


def vector(color, key, dens, sat, hs, ht):
    return {
        'name': 'vec_' + key, 'label': color, 'open': False,
        'params': [
            P(dens, 'Density', 'Film density of %s: positive deepens, negative lightens.' % color.lower()),
            P(sat, 'Saturation', 'Saturation of %s.' % color.lower()),
            P(hs, 'Hue Shift', 'Rotates the hue of %s.' % color.lower()),
            P(ht, 'Hue Recover', 'Pulls drifted %s hues back towards their reference.' % color.lower()),
        ]}


PLUGINS = [
    dict(
        key='drt', file='NODE_DRT.dctl',
        id='com.nodeone.ofx.NodeDRT', label='Node DRT', version=(1, 0),
        description='NODE_DRT — display rendering transform. Modified OpenDRT v1.0.1 '
                    'by Jed Smith, GPLv3, with film look presets fitted against '
                    'spektrafilm references. ' + WORKFLOW,
        groups=[
            {'name': 'grp_input', 'label': 'Input', 'open': True, 'params': [
                P('in_gamut', 'Gamut'),
                P('in_oetf', 'Log Curve'),
            ]},
            {'name': 'grp_display', 'label': 'Display', 'open': True, 'params': [
                P('display_encoding_preset', 'Output'),
                P('tn_Lp', 'Peak Nits'),
                P('tn_gb', 'HDR Grey Boost'),
                P('pt_hdr', 'HDR Purity'),
                P('out_clamp', 'Clamp To Display'),
            ]},
            {'name': 'grp_look', 'label': 'Look', 'open': True, 'params': [
                P('look_preset', 'Look'),
                P('look_intensity', 'Look Intensity'),
                P('look_bypass', 'Bypass Look'),
            ]},
            {'name': 'grp_toning', 'label': 'Toning', 'open': True, 'params': [
                P('print_tone_sel', 'Toning'),
                P('tone_intensity', 'Toning Intensity'),
                P('tone_bypass', 'Bypass Toning'),
            ]},
            {'name': 'grp_tone', 'label': 'Tone', 'open': True, 'params': [
                P('tonescale_preset', 'Tonescale'),
                P('tone_curve_bypass', 'Bypass Tone'),
            ]},
            {'name': 'grp_trims', 'label': 'Trims', 'open': True, 'params': [
                P('trim_con', 'Log Contrast'), P('trim_piv', 'Pivot'),
                P('trim_ovl', 'Overlay'),
                P('trim_sh', 'Shadows'), P('trim_hp', 'Highlight Purity'),
                P('trim_hd', 'Highlight Density'),
                P('trim_hs', 'Highlight Saturation'),
                P('trim_br', 'Brilliance'),
                P('trim_mp', 'Mid Purity'), P('trim_mp_pv', 'Mid Purity Pivot'),
                P('trim_bypass', 'Bypass Trims'),
                P('trim_reset', 'Reset Trims', synth='push',
                  hint='Returns every control in this group to its default in one click, as a single undo step. It reads the group itself rather than a hand-written list, so a control added here later is reset too without anyone having to remember. It does not touch anything outside the group - Color, White and the look are left exactly as they are.'),
            ]},
            {'name': 'grp_white', 'label': 'White', 'open': False, 'params': [
                P('wb_preset', 'Illuminant'),
                P('wb_kelvin', 'Kelvin'),
                P('wb_temp', 'Temp'),
                P('wb_tint', 'Tint'),
                P('wb_bypass', 'Bypass Illuminant'),
                P('_cwp', 'Creative White'), P('_cwp_rng', 'Creative White Range'),
                P('cw_bypass', 'Bypass Creative White'),
            ]},
            {'name': 'grp_colour', 'label': 'Color', 'open': False, 'params': [
                P('col_chroma', 'Chroma'),
                P('col_ptw', 'Path To White'),
                P('col_onset', 'White Onset'),
                P('col_weight', 'Color Weight'),
                P('col_dens', 'Color Density'),
                P('col_bypass', 'Bypass Color'),
            ]},
            {'name': 'grp_view', 'label': 'Scopes', 'open': False, 'params': [
                P('crv_enable', 'Curve View'), P('crv_size', 'Curve Size'),
                P('fc_overlay', 'False Color'),
                P('skin_check', 'Skin Check'),
                P('legend', 'Legend'),
            ]},
        ],
        hidden=['credits'],
        about=['NODE_DRT by Samuel Drouin.',
               'Modified OpenDRT v1.0.1 by Jed Smith, licensed GPLv3 — github.com/jedypod/open-display-transform. The rendering engine is his work; this plugin is a modified version and is distributed under the same licence, source included.',
               'Look presets fitted against spektrafilm references by Andrea Volpato, CC BY-SA 4.0 — github.com/andreavolpato/spektrafilm. No LUT data is embedded; what remains are fitted parameter values.',
               'Subtractive saturation model by Nikita Petrovich, MIT licence — the Chroma control in the Color group. See MIT-SubtractiveSaturation.txt.',
               'OpenFX support library: Academy Software Foundation, BSD 3-Clause.'],
    ),
]

