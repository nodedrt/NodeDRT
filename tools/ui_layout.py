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


# Reglage PROPRE AU PLUGIN (pas de contrepartie dans le DCTL) : l'etage Texture.
def TP(name, label, kind, default, min=0.0, max=1.0, step=0.01, hint=None, options=None):
    d = {'name': name, 'label': label, 'synth': 'param', 'kind': kind, 'default': default,
         'min': min, 'max': max, 'step': step}
    if kind == 'bool':
        d.update(min=0.0, max=1.0, step=1.0)
    if kind == 'choice':
        d['options'] = options
        d.update(min=0.0, max=float(len(options) - 1), step=1.0)
    if hint:
        d['hint'] = hint
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
        id='com.nodeone.ofx.NodeDRT', label='Node DRT', version=(1, 2),
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
            # TEXTURE : grain et halation, calcules par le plugin lui-meme (ils
            # lisent les pixels voisins sur plusieurs passes) sur l'image log
            # d'entree, AVANT le rendu - la ou la pellicule les cree. Les deux
            # sont eteints par defaut : le plugin rend exactement comme avant
            # tant qu'on ne les active pas.
            {'name': 'grp_texture', 'label': 'Texture', 'open': False, 'params': [
                SUB('grp_tex_grain', 'Grain', [
                    TP('tx_gr_on', 'Enable Grain', 'bool', 0,
                       hint='Film grain, modelled by measurement on film renders: strength per channel against density, '
                            'grain size per gauge, the correlation between the colour layers. Added to the log image '
                            'before the display rendering, so it rolls off with the picture like real grain.'),
                    TP('tx_gr_gauge', 'Format', 'choice', 1, options=['65mm', '35mm'],
                       hint='Film gauge. 65mm: fine, tight grain. 35mm: the classic cinema grain, larger and more visible.'),
                    TP('tx_gr_amt', 'Amount', 'float', 1.0, 0.0, 3.0, 0.01,
                       hint='Grain strength. 1 = the base film grain for the chosen format, set for a natural, true-to-film presence.'),
                    TP('tx_gr_size', 'Size', 'float', 1.0, 0.5, 2.0, 0.01,
                       hint='Grain scale. 1 = the base grain size for the chosen format, the same at any resolution.'),
                    TP('tx_gr_col', 'Color', 'float', 1.0, 0.0, 2.0, 0.01,
                       hint='0 = monochrome grain, 1 = the measured colour grain of the film, 2 = more colourful.'),
                    TP('tx_gr_sh', 'Shadows', 'float', 1.0, 0.0, 2.0, 0.01,
                       hint='Grain amount in the shadows (below about 1 stop under middle grey).'),
                    TP('tx_gr_md', 'Midtones', 'float', 1.0, 0.0, 2.0, 0.01,
                       hint='Grain amount in the midtones.'),
                    TP('tx_gr_hi', 'Highlights', 'float', 1.0, 0.0, 2.0, 0.01,
                       hint='Grain amount in the highlights (above about 1 stop over middle grey).'),
                    TP('tx_gr_anim', 'Animated', 'bool', 1,
                       hint='A new grain pattern every frame, like film. Off: one still pattern.'),
                    TP('tx_gr_seed', 'Seed', 'float', 0.0, 0.0, 999.0, 1.0,
                       hint='Changes the random pattern of the grain.'),
                ]),
                SUB('grp_tex_hal', 'Halation', [
                    TP('tx_hal_on', 'Enable Halation', 'bool', 0,
                       hint='The red-orange glow film gives around bright lights: light crossing the emulsion is '
                            'reflected by the film base back into the red layer. Modelled by measurement: source '
                            'threshold, radial spread and the weight of each colour layer. A flat highlight keeps '
                            'its own colour; the halo spreads out of it.'),
                    TP('tx_hal_str', 'Strength', 'float', 1.0, 0.0, 3.0, 0.01,
                       hint='Halation strength. 1 = the measured film halation.'),
                    TP('tx_hal_size', 'Size', 'float', 1.0, 0.25, 4.0, 0.01,
                       hint='Spread of the halo. 1 = the measured spread, scaled to the frame width.'),
                    TP('tx_hal_thr', 'Threshold', 'float', 0.0, -0.2, 0.2, 0.001,
                       hint='Moves the brightness at which lights start to glow. Negative = more of the picture glows, '
                            'positive = only the brightest lights.'),
                    TP('tx_hal_soft', 'Softness', 'float', 0.0, 0.0, 1.0, 0.01,
                       hint='Softens the halo: the tight rim of the film opens into a smooth, diffuse glow. The total '
                            'light of the halo is kept - only its shape changes - so Strength still means the same, '
                            'and a flat highlight is never touched. 0 = the measured film halo.'),
                    TP('tx_hal_warm', 'Warmth', 'float', 0.0, -1.0, 1.0, 0.01,
                       hint='Colour of the halo. Positive = redder, negative = more orange-yellow.'),
                ]),
                P('texture_reset', 'Reset Texture', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            {'name': 'grp_view', 'label': 'Scopes', 'open': False, 'params': [
                P('crv_enable', 'Curve View'), P('crv_size', 'Curve Size'),
                P('fc_overlay', 'False Color Stops'),
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
               'Texture (Grain, Halation): computed by the plugin on the log image before the display rendering. Grain and halation are models fitted by measurement on film-emulation renders - curves, kernels and weights only; no code or data of another product is included.',
               'OpenFX support library: Academy Software Foundation, BSD 3-Clause.'],
    ),
]

