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


# Bulles d'aide : vocabulaire de coloriste, quelques mots (v2). Appliquees a la fin du
# fichier sur chaque reglage, elles remplacent les textes longs du DCTL.
SHORT_HINTS = {'in_gamut': 'Source gamut.', 'in_oetf': 'Source log encoding.', 'display_encoding_preset': 'Output display standard.', 'tn_Lp': 'Display peak luminance (nits).', 'tn_gb': 'HDR mid-grey lift.', 'pt_hdr': 'HDR highlight chroma retention.', 'out_clamp': 'Clamp to display range.', 'wb_preset': 'Scene illuminant.', 'wb_kelvin': 'Illuminant CCT.', 'wb_temp': 'Temperature offset.', 'wb_tint': 'Tint offset (green/magenta).', 'wb_bypass': 'Bypass illuminant.', '_cwp': 'Creative white point.', '_cwp_rng': 'Creative white range.', 'cw_bypass': 'Bypass creative white.', 'white_reset': 'Reset White.', 'look_preset': 'Film print look.', 'look_intensity': 'Look mix.', 'look_bypass': 'Bypass look.', 'print_tone_sel': 'Print toning.', 'tone_intensity': 'Toning mix.', 'tone_bypass': 'Bypass toning.', 'tonescale_preset': 'Tone curve preset.', 'ts_intensity': 'Tone curve mix.', 'tone_curve_bypass': "Use the look's native curve.", 'look_reset': 'Reset Look.', 'col_chroma': 'Global chroma.', 'col_ptw': 'Path-to-white rate.', 'col_onset': 'Path-to-white onset.', 'col_weight': 'Subtractive saturation.', 'col_dens': 'Colour density (film).', 'col_bypass': 'Bypass Color.', 'color_reset': 'Reset Color.', 'dp_boost': 'Density gain, all colours.', 'dp_bypass': 'Bypass Density.', 'dp_hi': 'Highlight density.', 'dp_mid': 'Midtone density.', 'dp_sh': 'Shadow density.', 'dp_zpiv': 'Zone pivot.', 'dp_zsoft': 'Zone crossover softness.', 'dp_zones_smooth': 'Matte blur.', 'dp_show_zones': 'Show zone matte.', 'dp_zones_bypass': 'Bypass zones.', 'dp_zones_reset': 'Reset zones.', 'dp_red': 'Red density.', 'dp_yellow': 'Yellow density.', 'dp_green': 'Green density.', 'dp_cyan': 'Cyan density.', 'dp_blue': 'Blue density.', 'dp_magenta': 'Magenta density.', 'dp_red_rng': 'Red hue width.', 'dp_yellow_rng': 'Yellow hue width.', 'dp_green_rng': 'Green hue width.', 'dp_cyan_rng': 'Cyan hue width.', 'dp_blue_rng': 'Blue hue width.', 'dp_magenta_rng': 'Magenta hue width.', 'dp_focus': 'Saturation threshold.', 'dp_colors_smooth': 'Matte blur.', 'dp_show': 'Show colour matte.', 'dp_colors_bypass': 'Bypass colours.', 'density_reset': 'Reset colour density.', 'trim_crv': 'Curve overlay (linked to Scopes).', 'trim_con': 'Log contrast.', 'trim_piv': 'Contrast pivot.', 'trim_ovl': 'Overlay contrast.', 'trim_blift': 'Black lift (toe).', 'trim_blift_pv': 'Lift range.', 'trim_wroll': 'White roll-off (shoulder).', 'trim_wroll_pv': 'Shoulder start.', 'trim_sh': 'Shadow contrast.', 'trim_con_bypass': 'Bypass Contrast.', 'trim_hp': 'Highlight chroma.', 'trim_hd': 'Highlight density.', 'trim_hs': 'Highlight saturation.', 'trim_br': 'Saturated colour luminance.', 'trim_hl_bypass': 'Bypass Highlights.', 'trim_mp': 'Midtone chroma.', 'trim_mp_pv': 'Midtone chroma pivot.', 'trim_mid_bypass': 'Bypass Midtones.', 'trim_reset': 'Reset Trims.', 'skin_zones': 'Show skin matte.', 'skin_mhc': 'Hue centre.', 'skin_mhue': 'Hue width.', 'skin_msl': 'Low saturation limit.', 'skin_msx': 'High saturation limit.', 'skin_mdk': 'Low luminance limit.', 'skin_soft': 'Qualifier softness.', 'skin_medge': 'Matte blur.', 'skin_mask_reset': 'Reset matte.', 'trim_skin': 'Pull to skin tone line.', 'trim_skin_sat': 'Skin saturation.', 'skin_col_bypass': 'Bypass skin colour.', 'skin_hi': 'Skin highlights exposure.', 'skin_mid': 'Skin midtones exposure.', 'skin_sh': 'Skin shadows exposure.', 'skin_piv': 'Skin zone pivot.', 'skin_light_bypass': 'Bypass skin light.', 'skin_reset': 'Reset Skin.', 'tx_gr_on': 'Film grain.', 'tx_gr_gauge': 'Film gauge.', 'tx_gr_amt': 'Grain amount.', 'tx_gr_size': 'Grain size.', 'tx_gr_col': 'Grain chroma.', 'tx_gr_sh': 'Grain, shadows.', 'tx_gr_md': 'Grain, midtones.', 'tx_gr_hi': 'Grain, highlights.', 'tx_gr_anim': 'Animated grain.', 'tx_gr_seed': 'Grain seed.', 'tx_gr_bypass': 'Bypass grain.', 'texture_reset': 'Reset Texture.', 'crv_enable': 'Curve overlay (linked to Trims).', 'crv_size': 'Curve overlay size.', 'fc_overlay': 'False colour (stops).', 'skin_check': 'Skin tone line deviation.', 'legend': 'Overlay legend.', 'credits': 'Credits and licences.'}

PLUGINS = [
    dict(
        key='drt', file='NODE_DRT.dctl',
        id='com.nodeone.ofx.NodeDRT2', label='Node DRT v2', version=(2, 0),
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
            # DENSITY PRO (de RELIEF) : densite film par zone et par couleur,
            # calculee par le plugin sur l'image log d'entree, avant Texture et
            # avant le rendu. Tout a 0 : le plugin rend exactement comme avant.
            {'name': 'grp_density', 'label': 'Density', 'open': False, 'params': [
                TP('dp_mask_focus', 'Mask Focus', 'float', -1.0, -1.0, 10.0, 1.0),
                SUB('grp_dp_zones', 'Zones', [
                    TP('dp_hi', 'Highlights Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density of colours in the highlights. Positive = denser (darker, richer), negative = lighter.'),
                    TP('dp_mid', 'Midtones Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density of colours around middle grey. Positive = denser, negative = lighter.'),
                    TP('dp_sh', 'Shadows Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density of colours in the shadows. Positive = denser, negative = lighter.'),
                    TP('dp_zpiv', 'Zones Pivot', 'float', 0.0, -3.0, 3.0, 0.01,
                       hint='Moves the three zones in stops: negative = the highlights zone starts lower (more of the image is highlights), positive = higher.'),
                    TP('dp_zsoft', 'Zones Softness', 'float', 0.5, 0.0, 1.0, 0.01,
                       hint='Overlap between the zones: 0 = separate zones (0.75 stop transitions), 0.5 = default, 1 = very blended (4.5 stops). Use Show Zones to see them.'),
                    TP('dp_zones_smooth', 'Mask Smoothness', 'float', 0.0, 0.0, 1.0, 0.01,
                       hint='Softness of the zone selection in the picture, like the blur of a qualifier: blurred over 10 px at 0 (the default, already smooth) up to 40 px at 1, of a 1080 frame. An object is never cut into pieces, no edge shows a step, and a neutral next to a coloured object never moves.'),
                    TP('dp_show_zones', 'Show Zones', 'bool', 0,
                       hint='Smart view of the zones. Touch a zone slider: only that zone is shown, the rest of the picture turns grey. '
                            'Touch Show Zones itself, Zones Pivot or Zones Softness: the map of the three zones, Shadows blue, Midtones green, '
                            'Highlights orange, with their soft overlaps. Turning it on turns Show Colors off. View only: nothing is rendered with it.'),
                    TP('dp_zones_bypass', 'Bypass Zones', 'bool', 0,
                       hint='Skips the three zone sliders. Their settings are kept.'),
                    P('dp_zones_reset', 'Reset Zones', synth='push', hint='Returns the Zones controls (densities, pivot, softness, view, bypass) to their default in one click, as a single undo step. The colours are not touched.'),
                ]),
                SUB('grp_dp_colors', 'Colors', [
                    TP('dp_red', 'Red Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density on red hues. Positive = denser (darker, richer), negative = lighter.'),
                    TP('dp_red_rng', 'Red Range', 'float', 1.0, 0.1, 4.0, 0.01,
                       hint='Width of the colour zone. 1 = precise (full effect within 6 deg of hue, fades out at 20 deg). Lower = even narrower, higher = wider, up to the neighbouring colours at 4.'),
                    TP('dp_yellow', 'Yellow Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density on yellow hues. Positive = denser (darker, richer), negative = lighter.'),
                    TP('dp_yellow_rng', 'Yellow Range', 'float', 1.0, 0.1, 4.0, 0.01,
                       hint='Width of the colour zone. 1 = precise (full effect within 6 deg of hue, fades out at 20 deg). Lower = even narrower, higher = wider, up to the neighbouring colours at 4.'),
                    TP('dp_green', 'Green Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density on green hues. Positive = denser (darker, richer), negative = lighter.'),
                    TP('dp_green_rng', 'Green Range', 'float', 1.0, 0.1, 4.0, 0.01,
                       hint='Width of the colour zone. 1 = precise (full effect within 6 deg of hue, fades out at 20 deg). Lower = even narrower, higher = wider, up to the neighbouring colours at 4.'),
                    TP('dp_cyan', 'Cyan Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density on cyan hues. Positive = denser (darker, richer), negative = lighter.'),
                    TP('dp_cyan_rng', 'Cyan Range', 'float', 1.0, 0.1, 4.0, 0.01,
                       hint='Width of the colour zone. 1 = precise (full effect within 6 deg of hue, fades out at 20 deg). Lower = even narrower, higher = wider, up to the neighbouring colours at 4.'),
                    TP('dp_blue', 'Blue Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density on blue hues. Positive = denser (darker, richer), negative = lighter.'),
                    TP('dp_blue_rng', 'Blue Range', 'float', 1.0, 0.1, 4.0, 0.01,
                       hint='Width of the colour zone. 1 = precise (full effect within 6 deg of hue, fades out at 20 deg). Lower = even narrower, higher = wider, up to the neighbouring colours at 4.'),
                    TP('dp_magenta', 'Magenta Density', 'float', 0.0, -100.0, 100.0, 0.1,
                       hint='Density on magenta hues. Positive = denser (darker, richer), negative = lighter.'),
                    TP('dp_magenta_rng', 'Magenta Range', 'float', 1.0, 0.1, 4.0, 0.01,
                       hint='Width of the colour zone. 1 = precise (full effect within 6 deg of hue, fades out at 20 deg). Lower = even narrower, higher = wider, up to the neighbouring colours at 4.'),
                    TP('dp_focus', 'Saturation Focus', 'float', 40.0, 0.0, 100.0, 0.1,
                       hint='0 = also acts on softly coloured areas, 100 = only on strongly saturated colours. Neutrals never move.'),
                    TP('dp_colors_smooth', 'Mask Smoothness', 'float', 0.0, 0.0, 1.0, 0.01,
                       hint='Softness of the colour selection in the picture, like the blur of a qualifier: blurred over 10 px at 0 (the default, already smooth) up to 40 px at 1, of a 1080 frame. An object is never cut into pieces, no edge shows a step, and a neutral next to a coloured object never moves.'),
                    TP('dp_show', 'Show Colors', 'bool', 0,
                       hint='Smart view of the colours. Touch a colour or its Range: only that colour is shown, the rest of the picture turns grey. '
                            'Touch Show Colors itself or Saturation Focus: every active colour. Turning it on turns Show Zones off. View only.'),
                    TP('dp_colors_bypass', 'Bypass Colors', 'bool', 0,
                       hint='Skips the six colour sliders. Their settings are kept.'),
                    P('density_reset', 'Reset Density Color', synth='push', hint='Returns the Colors controls (the six colours and their ranges, Saturation Focus, view, bypass) to their default in one click, as a single undo step. The zones are not touched.'),
                    TP('dp_boost', 'Global Strength', 'float', 0.0, 0.0, 100.0, 0.1,
                       hint='Overall strength of all Density sliders: 0 = x1, 100 = x2, with a soft ceiling of 1.75 stops so a colour never goes to black.'),
                ]),
            ]},
            {'name': 'grp_trims', 'label': 'Trims', 'open': False, 'params': [
                TP('trim_crv', 'Curve View', 'bool', 0),
                SUB('grp_trims_con', 'Contrast', [
                    P('trim_con', 'Log Contrast'), P('trim_piv', 'Pivot'),
                    P('trim_ovl', 'Overlay'),
                    P('trim_blift', 'Black Lift'),
                    P('trim_blift_pv', 'Black Lift Pivot'),
                    P('trim_wroll', 'White Roll-Off'),
                    P('trim_wroll_pv', 'White Roll-Off Pivot'),
                    P('trim_sh', 'Shadows'),
                    P('trim_con_bypass', 'Bypass Contrast'),
                ]),
                SUB('grp_trims_hl', 'Highlights', [
                    P('trim_hp', 'Highlight Purity'),
                    P('trim_hd', 'Highlight Density'),
                    P('trim_hs', 'Highlight Saturation'),
                    P('trim_br', 'Brilliance'),
                    P('trim_hl_bypass', 'Bypass Highlights'),
                ]),
                SUB('grp_trims_mid', 'Midtones', [
                    P('trim_mp', 'Mid Purity'), P('trim_mp_pv', 'Mid Purity Pivot'),
                    P('trim_mid_bypass', 'Bypass Midtones'),
                ]),
                P('trim_reset', 'Reset Trims', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            # SKIN : les noms OFX trim_skin / trim_skin_sat sont gardes.
            {'name': 'grp_skin', 'label': 'Skin', 'open': False, 'params': [
                # MASQUE (v2) : comme un qualifieur - Show Mask d'abord, puis teinte,
                # saturation, ombres, douceur, flou. Chaque reglage fait une chose et
                # se voit sur Show Mask. Bipolaires, 0 = le masque mesure.
                SUB('grp_skin_mask', 'Mask', [
                    P('skin_zones', 'Show Mask'),
                    P('skin_mhc', 'Hue Center'),
                    P('skin_mhue', 'Hue Width'),
                    P('skin_msl', 'Low Saturation'),
                    P('skin_msx', 'High Saturation'),
                    P('skin_mdk', 'Shadows Reach'),
                    P('skin_soft', 'Softness'),
                    P('skin_medge', 'Edge Blur'),
                    P('skin_mask_reset', 'Reset Mask', synth='push', hint='Returns the mask controls (and Show Mask) to the mask measured on real faces in one click, as a single undo step. Color and Light are not touched.'),
                ]),
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
                    P('skin_light_bypass', 'Bypass Light'),
                ]),
                P('skin_reset', 'Reset Skin', synth='push', hint='Returns every control in this group, sub-sections included, to its default in one click, as a single undo step. Nothing outside the group is touched.'),
            ]},
            # TEXTURE : grain (la halation a ete retiree en 1.3), calcule par le plugin lui-meme (ils
            # lisent les pixels voisins sur plusieurs passes) sur l'image log
            # d'entree, AVANT le rendu - la ou la pellicule les cree. Les deux
            # sont eteints par defaut : le plugin rend exactement comme avant
            # tant qu'on ne les active pas.
            {'name': 'grp_texture', 'label': 'Texture', 'open': False, 'params': [
                SUB('grp_tex_grain', 'Grain', [
                    TP('tx_gr_on', 'Enable Grain', 'bool', 0,
                       hint='Film grain from the physical grain model of spektrafilm (silver-halide particles per colour layer): '
                            'strength per channel against density, grain size per gauge, independent colour layers. Added to the log image '
                            'before the display rendering, so it rolls off with the picture like real grain.'),
                    TP('tx_gr_gauge', 'Format', 'choice', 1, options=['65mm', '35mm', '16mm', '8mm'],
                       hint='Film gauge: the same film on a smaller frame shows bigger grain. 65mm: fine and tight. 35mm: the classic cinema grain. 16mm: documentary, clearly visible. 8mm: home movie, heavy.'),
                    TP('tx_gr_amt', 'Amount', 'float', 1.0, 0.0, 3.0, 0.01,
                       hint='Grain strength. 1 = the film grain as modelled for the chosen format, true to film at any resolution.'),
                    TP('tx_gr_size', 'Size', 'float', 1.0, 0.5, 2.0, 0.01,
                       hint='Grain particle size. 1 = the film as modelled; 2 = particles twice as large (coarser and stronger).'),
                    TP('tx_gr_col', 'Color', 'float', 1.0, 0.0, 2.0, 0.01,
                       hint='0 = monochrome grain, 1 = the colour grain of the film (independent colour layers), 2 = more colourful.'),
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
                    TP('tx_gr_bypass', 'Bypass Grain', 'bool', 0,
                       hint='Skips the grain while keeping every setting, to compare with and without. Same as unticking Enable Grain, but your choice stays visible.'),
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
        about=['NODE DRT v2 by Samuel Drouin.',
               'Modified OpenDRT v1.0.1 by Jed Smith, licensed GPLv3 — github.com/jedypod/open-display-transform. The rendering engine is his work; this plugin is a modified version and is distributed under the same licence, source included.',
               'Looks 1-7: parameter sets fitted against spectral print simulations by spektrafilm (Andrea Volpato, CC BY-SA 4.0, github.com/andreavolpato/spektrafilm); v2 refits their tone curves for a continuous shoulder. No LUT data is embedded.',
               'Subtractive saturation model by Nikita Petrovich, MIT licence — the Chroma control in the Color group. See MIT-SubtractiveSaturation.txt.',
               'Skin Line turns hue in Oklab by Bjorn Ottosson (public domain / MIT), written from the published formulas.',
               'Grain: computed by the plugin on the log image before the display rendering. Strengths and gauge ratios measured on the grain model of spektrafilm (Andrea Volpato); overall level from Kodak published RMS granularity. No code or data of another product is included.',
               'Density: from RELIEF by Samuel Drouin - density by zone and by colour, with hue windows in Oklab by Bjorn Ottosson (public domain / MIT), written from the published formulas.',
               'OpenFX support library: Academy Software Foundation, BSD 3-Clause.'],
    ),
]



def _apply_short_hints(items):
    for it in items:
        if isinstance(it, dict) and it.get('sub'):
            _apply_short_hints(it['params'])
        elif isinstance(it, dict) and it.get('name') in SHORT_HINTS:
            it['hint'] = SHORT_HINTS[it['name']]
        elif isinstance(it, str) and False:
            pass


for _pl in PLUGINS:
    for _g in _pl['groups']:
        _apply_short_hints(_g['params'])
