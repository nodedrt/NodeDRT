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


# Sous-section d'un groupe : un groupe OFX standard niche dans son parent,
# repliable, comme dans les effets livres avec Resolve.
def SUB(name, label, params, open=True):
    return {'sub': True, 'name': name, 'label': label, 'open': open, 'params': params}


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
            # ORGANISATION (9 octobre 2026). Les groupes suivent l'ordre du
            # traitement : ce qui entre et ce qui sort d'abord - a regler une
            # fois - puis la balance des blancs (posee en lumiere de scene,
            # avant le look), le look, la couleur, les trims, la peau, et les
            # instruments a la fin. Chaque groupe est decoupe en sous-parties
            # repliables, chacune avec son bypass a l'interieur ; chaque groupe
            # creatif a son Reset. Les noms OFX ne changent pas : un etalonnage
            # deja fait retrouve toutes ses valeurs.
            # A l'ouverture : seul Input / Output est deplie (ce qu'on regle en
            # premier) ; les sous-parties restent depliees a l'interieur, pour
            # que chaque groupe montre ses reglages des qu'on l'ouvre.
            {'name': 'grp_io', 'label': 'Input / Output', 'open': True, 'params': [
                SUB('grp_input', 'Input', [
                    P('in_gamut', 'Gamut'),
                    P('in_oetf', 'Log Curve'),
                ]),
                SUB('grp_display', 'Output', [
                    P('display_encoding_preset', 'Output'),
                    P('tn_Lp', 'Peak Nits'),
                    P('tn_gb', 'HDR Grey Boost'),
                    P('pt_hdr', 'HDR Purity'),
                    P('out_clamp', 'Clamp To Display'),
                ]),
            ]},
            {'name': 'grp_white', 'label': 'White', 'open': False, 'params': [
                SUB('grp_white_ill', 'Illuminant', [
                    P('wb_preset', 'Illuminant'),
                    P('wb_kelvin', 'Kelvin'),
                    P('wb_temp', 'Temp'),
                    P('wb_tint', 'Tint'),
                    P('wb_bypass', 'Bypass Illuminant'),
                ]),
                SUB('grp_white_cw', 'Creative White', [
                    P('_cwp', 'Creative White'), P('_cwp_rng', 'Creative White Range'),
                    P('cw_bypass', 'Bypass Creative White'),
                ]),
                P('white_reset', 'Reset White', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            # LOOK / TONING / TONE : les trois decident ensemble de ce qu'est
            # le look - la couleur, le virage, la courbe. Le nom 'grp_look' est
            # garde : c'est lui qui porte l'etat ouvert/ferme.
            {'name': 'grp_look', 'label': 'Look / Toning / Tone', 'open': False, 'params': [
                SUB('grp_look_lk', 'Look', [
                    P('look_preset', 'Look'),
                    P('look_intensity', 'Look Intensity'),
                    P('look_bypass', 'Bypass Look'),
                ]),
                SUB('grp_look_tn', 'Toning', [
                    P('print_tone_sel', 'Toning'),
                    P('tone_intensity', 'Toning Intensity'),
                    P('tone_bypass', 'Bypass Toning'),
                ]),
                SUB('grp_look_ts', 'Tone', [
                    P('tonescale_preset', 'Tonescale'),
                    P('ts_intensity', 'Tonescale Intensity'),
                    P('tone_curve_bypass', 'Bypass Tone'),
                ]),
                P('look_reset', 'Reset Look', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            {'name': 'grp_colour', 'label': 'Color', 'open': False, 'params': [
                P('col_chroma', 'Chroma'),
                P('col_ptw', 'Path To White'),
                P('col_onset', 'White Onset'),
                P('col_weight', 'Color Weight'),
                P('col_dens', 'Color Density'),
                P('col_bypass', 'Bypass Color'),
                P('color_reset', 'Reset Color', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            {'name': 'grp_trims', 'label': 'Trims', 'open': False, 'params': [
                SUB('grp_trims_con', 'Contrast', [
                    P('trim_con', 'Log Contrast'), P('trim_piv', 'Pivot'),
                    P('trim_ovl', 'Overlay'),
                    P('trim_con_bypass', 'Bypass Contrast'),
                ]),
                SUB('grp_trims_hl', 'Shadows & Highlights', [
                    P('trim_sh', 'Shadows'), P('trim_hp', 'Highlight Purity'),
                    P('trim_hd', 'Highlight Density'),
                    P('trim_hs', 'Highlight Saturation'),
                    P('trim_br', 'Brilliance'),
                    P('trim_hl_bypass', 'Bypass Shadows & Highlights'),
                ]),
                SUB('grp_trims_mid', 'Midtones', [
                    P('trim_mp', 'Mid Purity'), P('trim_mp_pv', 'Mid Purity Pivot'),
                    P('trim_mid_bypass', 'Bypass Midtones'),
                ]),
                P('trim_reset', 'Reset Trims', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            # SKIN : les noms OFX trim_skin / trim_skin_sat sont gardes.
            {'name': 'grp_skin', 'label': 'Skin', 'open': False, 'params': [
                SUB('grp_skin_col', 'Color', [
                    P('trim_skin', 'Skin Line'),
                    P('trim_skin_sat', 'Skin Saturation'),
                    P('skin_col_bypass', 'Bypass Color'),
                ]),
                SUB('grp_skin_light', 'Light', [
                    P('skin_hi', 'Highlights'),
                    P('skin_mid', 'Midtones'),
                    P('skin_sh', 'Shadows'),
                    P('skin_piv', 'Zone Pivot'),
                    P('skin_soft', 'Mask Softness'),
                    P('skin_zones', 'Show Zones'),
                    P('skin_light_bypass', 'Bypass Light'),
                ]),
                P('skin_reset', 'Reset Skin', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            {'name': 'grp_view', 'label': 'Scopes', 'open': False, 'params': [
                P('crv_enable', 'Curve View'), P('crv_size', 'Curve Size'),
                P('fc_overlay', 'False Color'),
                P('skin_check', 'Skin Check'),
                P('legend', 'Legend'),
            ]},
        ],
        hidden=['credits', 'trial_mark'],
        about=['NODE_DRT by Samuel Drouin.',
               'Modified OpenDRT v1.0.1 by Jed Smith, licensed GPLv3 — github.com/jedypod/open-display-transform. The rendering engine is his work; this plugin is a modified version and is distributed under the same licence, source included.',
               'Look presets fitted against spektrafilm references by Andrea Volpato, CC BY-SA 4.0 — github.com/andreavolpato/spektrafilm. No LUT data is embedded; what remains are fitted parameter values.',
               'Subtractive saturation model by Nikita Petrovich, MIT licence — the Chroma control in the Color group. See MIT-SubtractiveSaturation.txt.',
               'Skin Line turns hue in Oklab by Bjorn Ottosson (public domain / MIT), written from the published formulas.',
               'OpenFX support library: Academy Software Foundation, BSD 3-Clause.'],
    ),
]

