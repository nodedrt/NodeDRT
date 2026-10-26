// =============================================================================
//  NODE_ONE OFX — DCTL compatibility layer, Metal Shading Language
// -----------------------------------------------------------------------------
//  Compiled at runtime (MTLDevice newLibraryWithSource) with fast-math OFF:
//  no reassociation, NaN and infinity keep their IEEE meaning.
//  PERFORMANCE (26 octobre 2026) : pow, exp, exp2, log, log2 et la racine
//  cubique utilisent les versions RAPIDES du GPU (metal::fast), qui coutent
//  une fraction des versions precises. Mesure sur 4 images reelles et tous les
//  reglages : ecart a la version precise 0.0002/255 au pire sans reglage peau,
//  0.02/255 avec - invisible - pour un rendu 2.2 fois plus rapide. pow rapide
//  n'est utilise que pour une base strictement positive (son domaine) : zero,
//  negatif, NaN passent par la version precise et gardent leur resultat exact.
//  sin, cos, atan2 et le reste restent PRECIS : leurs versions rapides
//  faussaient 0.5 pour cent des pixels.
//  No "using namespace metal": DCTL helper names can never collide with the
//  Metal standard library.
// =============================================================================
#include <metal_stdlib>

// The DCTLs carry variables kept for readability or future use; that is the
// author's business, not a defect. Keep the kernel log free for real errors.
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunused-but-set-variable"

#define __RESOLVE_VER_MAJOR__ 20
#define __RESOLVE_VER_MINOR__ 0
#define __DEVICE__
#define __CONSTANT__ constant
#define __CONSTANTREF__ constant
#define __TEXTURE__ DctlTex
#define __PARAMSREF__ constant
#define DEVICE_IS_METAL 1

inline float2 make_float2(float x, float y) { return float2(x, y); }
inline float3 make_float3(float x, float y, float z) { return float3(x, y, z); }
inline float4 make_float4(float x, float y, float z, float w) { return float4(x, y, z, w); }

inline float _fabs(float x) { return metal::fabs(x); }
inline float _powf(float x, float y) { return x > 0.0f ? metal::fast::powr(x, y) : metal::precise::pow(x, y); }
inline float _sqrtf(float x) { return metal::sqrt(x); }
inline float _rsqrtf(float x) { return metal::rsqrt(x); }
// Metal has no cbrt(). Same expression as the CPU layer, so both agree.
inline float _cbrtf(float x) { return x != 0.0f ? metal::copysign(metal::fast::powr(metal::fabs(x), 1.0f / 3.0f), x) : x; }
inline float _expf(float x) { return metal::fast::exp(x); }
inline float _exp2f(float x) { return metal::fast::exp2(x); }
inline float _exp10f(float x) { return metal::exp10(x); }
inline float _logf(float x) { return metal::fast::log(x); }
inline float _log2f(float x) { return metal::fast::log2(x); }
inline float _log10f(float x) { return metal::log10(x); }
inline float _sinf(float x) { return metal::precise::sin(x); }
inline float _cosf(float x) { return metal::precise::cos(x); }
inline float _tanf(float x) { return metal::precise::tan(x); }
inline float _asinf(float x) { return metal::precise::asin(x); }
inline float _acosf(float x) { return metal::precise::acos(x); }
inline float _atanf(float x) { return metal::precise::atan(x); }
inline float _atan2f(float y, float x) { return metal::precise::atan2(y, x); }
inline float _sinhf(float x) { return metal::precise::sinh(x); }
inline float _coshf(float x) { return metal::precise::cosh(x); }
inline float _tanhf(float x) { return metal::precise::tanh(x); }
inline float _hypotf(float x, float y) { return metal::sqrt(x * x + y * y); }
inline float _fmod(float x, float y) { return metal::fmod(x, y); }
inline float _fmodf(float x, float y) { return metal::fmod(x, y); }
inline float _floorf(float x) { return metal::floor(x); }
inline float _floor(float x) { return metal::floor(x); }
inline float _ceilf(float x) { return metal::ceil(x); }
inline float _ceil(float x) { return metal::ceil(x); }
inline float _truncf(float x) { return metal::trunc(x); }
inline float _round(float x) { return metal::round(x); }
inline float _roundf(float x) { return metal::round(x); }
inline float _fmaxf(float a, float b) { return metal::fmax(a, b); }
inline float _fminf(float a, float b) { return metal::fmin(a, b); }
inline float _fdimf(float a, float b) { return metal::fdim(a, b); }
inline float _fmaf(float a, float b, float c) { return metal::fma(a, b, c); }
inline float _copysignf(float a, float b) { return metal::copysign(a, b); }
inline float _ldexpf(float a, int e) { return metal::ldexp(a, e); }
inline float _clampf(float x, float lo, float hi) { return metal::fmin(metal::fmax(x, lo), hi); }
inline float _saturatef(float x) { return metal::fmin(metal::fmax(x, 0.0f), 1.0f); }
inline float _mix(float a, float b, float t) { return a + (b - a) * t; }
inline float3 _mix(float3 a, float3 b, float t) { return a + (b - a) * t; }
inline int _isnan(float x) { return metal::isnan(x) ? 1 : 0; }
inline int _isinf(float x) { return metal::isinf(x) ? 1 : 0; }
inline int _isfinite(float x) { return metal::isfinite(x) ? 1 : 0; }

// One colour channel of the source image. DCTL coordinates: origin top-left.
// Reads outside the frame clamp to the nearest edge pixel.
struct DctlTex {
    const device float* base;
    int rowFloats;
    int w, h, ch;
    int flipY;
};
inline float _tex2D(DctlTex t, int x, int y) {
    x = x < 0 ? 0 : (x >= t.w ? t.w - 1 : x);
    y = y < 0 ? 0 : (y >= t.h ? t.h - 1 : y);
    const int row = t.flipY ? (t.h - 1 - y) : y;
    return t.base[row * t.rowFloats + x * 4 + t.ch];
}

#line 1 "node_one_params"
enum { i_xyz, i_ap0, i_ap1, i_p3d65, i_rec2020, i_rec709, i_awg3, i_awg4, i_rwg, i_sgamut3, i_sgamut3cine, i_vgamut, i_bmdwg, i_egamut, i_egamut2, i_davinciwg };
enum { ioetf_linear, ioetf_davinci_intermediate, ioetf_filmlight_tlog, ioetf_acescct, ioetf_arri_logc3, ioetf_arri_logc4, ioetf_redlog3g10, ioetf_panasonic_vlog, ioetf_sony_slog3, ioetf_fuji_flog };
enum { look0, look1, look2, look3, look4, look5, look6, look7 };
enum { ptn0, ptn1, ptn2, ptn3, ptn4, ptn5, ptn6, ptn7, ptn8 };
enum { wb0, wb1, wb2, wb3, wb4, wb5, wb6, wb7, wb8, wb9, wb10, wb11, wb12, wb13, wb14, wb15, wb16, wb17 };
enum { _cwp0, _cwp1, _cwp2, _cwp3, _cwp4 };
enum { tsprst0, tsprst1, tsprst2, tsprst3, tsprst4, tsprst5, tsprst6, tsprst7, tsprst8, tsprst9 };
enum { cr0, cr1, cr2, cr3, cr4, cr5, cr6, cr7, cr8, cr9 };
enum { rec1886, srgb, displayp3, rec2100pq, rec2100hlg, dolbypq };
struct DctlParams {
    int in_gamut;
    int in_oetf;
    float tn_Lp;
    float tn_gb;
    float pt_hdr;
    int out_clamp;
    int crv_enable;
    float crv_size;
    int fc_overlay;
    int skin_check;
    int legend;
    int look_preset;
    int look_bypass;
    int print_tone_sel;
    int tone_bypass;
    int wb_preset;
    float wb_kelvin;
    float wb_temp;
    float wb_tint;
    int wb_bypass;
    int cw_bypass;
    int _cwp;
    float _cwp_rng;
    float col_weight;
    float col_dens;
    int col_bypass;
    float col_chroma;
    float col_ptw;
    float col_onset;
    int trim_con_bypass;
    int trim_hl_bypass;
    int trim_mid_bypass;
    float trim_con;
    float trim_piv;
    float trim_ovl;
    float trim_sh;
    float trim_hp;
    float trim_hd;
    float trim_br;
    float trim_hs;
    float trim_mp;
    float trim_mp_pv;
    float trim_skin;
    float trim_skin_sat;
    float skin_piv;
    float skin_soft;
    int skin_zones;
    int skin_col_bypass;
    int skin_light_bypass;
    float skin_hi;
    float skin_mid;
    float skin_sh;
    int tone_curve_bypass;
    int tonescale_preset;
    float ts_intensity;
    int credits;
    int trial_mark;
    int display_encoding_preset;
    float look_intensity;
    float tone_intensity;
};
#line 1 "NODE_DRT.dctl"














































































































































































































































































































































#if ((__RESOLVE_VER_MAJOR__ > 19)) || ((__RESOLVE_VER_MAJOR__ == 19) && (__RESOLVE_VER_MINOR__ >= 1))

























#endif




#define matrix_ap0_to_xyz make_float3x3(make_float3(0.93863094875f, -0.00574192055f, 0.017566898852f), make_float3(0.338093594922f, 0.727213902811f, -0.065307497733f), make_float3(0.000723121511f, 0.000818441849f, 1.0875161874f))
#define matrix_ap1_to_xyz make_float3x3(make_float3(0.652418717672f, 0.127179925538f, 0.170857283842f), make_float3(0.268064059194f, 0.672464478993f, 0.059471461813f), make_float3(-0.00546992851f, 0.005182799977f, 1.08934487929f))
#define matrix_rec709_to_xyz make_float3x3(make_float3(0.412390917540f, 0.357584357262f, 0.180480793118f), make_float3(0.212639078498f, 0.715168714523f, 0.072192311287f), make_float3(0.019330825657f, 0.119194783270f, 0.950532138348f))
#define matrix_p3d65_to_xyz make_float3x3(make_float3(0.486571133137f, 0.265667706728f, 0.198217317462f), make_float3(0.228974640369f, 0.691738605499f, 0.079286918044f), make_float3(0.0f, 0.045113388449, 1.043944478035f))
#define matrix_xyz_to_p3d65 make_float3x3(make_float3(2.49349691194f, -0.931383617919f, -0.402710784451f), make_float3(-0.829488969562f, 1.76266406032f, 0.023624685842f), make_float3(0.035845830244f, -0.076172389268f, 0.956884524008f))
#define matrix_rec2020_to_xyz make_float3x3(make_float3(0.636958122253f, 0.144616916776f, 0.168880969286f), make_float3(0.262700229883f, 0.677998125553f, 0.059301715344f), make_float3(0.0f, 0.028072696179, 1.060985088348f))
#define matrix_arriwg3_to_xyz make_float3x3(make_float3(0.638007619284f, 0.214703856337f, 0.097744451431f), make_float3(0.291953779f, 0.823841041511f, -0.11579482051f), make_float3(0.002798279032f, -0.067034235689f, 1.15329370742f))
#define matrix_arriwg4_to_xyz make_float3x3(make_float3(0.704858320407f, 0.12976029517f, 0.115837311474f), make_float3(0.254524176404f, 0.781477732712f, -0.036001909116f), make_float3(0.0f, 0.0f, 1.08905775076f))
#define matrix_redwg_to_xyz make_float3x3(make_float3(0.735275208950f, 0.068609409034f, 0.146571278572f), make_float3(0.286694079638f, 0.842979073524f, -0.129673242569f), make_float3(-0.079680845141f, -0.347343206406, 1.516081929207f))
#define matrix_sonysgamut3_to_xyz make_float3x3(make_float3(0.706482713192f, 0.128801049791f, 0.115172164069f), make_float3(0.270979670813f, 0.786606411221f, -0.057586082034f), make_float3(-0.009677845386f, 0.004600037493f, 1.09413555865f))
#define matrix_sonysgamut3cine_to_xyz make_float3x3(make_float3(0.599083920758f, 0.248925516115f, 0.102446490178f), make_float3(0.215075820116f, 0.885068501744f, -0.100144321859f), make_float3(-0.032065849545f, -0.027658390679f, 1.14878199098f))
#define matrix_vgamut_to_xyz make_float3x3(make_float3(0.679644469878f, 0.15221141244f, 0.118600044733), make_float3(0.26068555009f, 0.77489446333f, -0.03558001342), make_float3(-0.009310198218f, -0.004612467044f, 1.10298041602))
#define matrix_bmdwg_to_xyz make_float3x3(make_float3(0.606538414955f, 0.220412746072f, 0.123504832387f), make_float3(0.267992943525f, 0.832748472691f, -0.100741356611f), make_float3(-0.029442556202f, -0.086612440646, 1.205112814903f))
#define matrix_egamut_to_xyz make_float3x3(make_float3(0.705396831036f, 0.164041340351f, 0.081017754972f), make_float3(0.280130714178f, 0.820206701756f, -0.100337378681f), make_float3(-0.103781513870f, -0.072907261550, 1.265746593475f))
#define matrix_egamut2_to_xyz make_float3x3(make_float3(0.736477700184f, 0.130739651087f, 0.083238575781f), make_float3(0.275069984406f, 0.828017790216f, -0.103087774621f), make_float3(-0.124225154248f, -0.087159767391f, 1.3004426724f))
#define matrix_davinciwg_to_xyz make_float3x3(make_float3(0.700622320175f, 0.148774802685f, 0.101058728993f), make_float3(0.274118483067f, 0.873631775379f, -0.147750422359f), make_float3(-0.098962903023f, -0.137895315886, 1.325916051865f))


#define matrix_p3_to_p3_d50 make_float3x3(make_float3(0.9287127388f, 0.06578032793f, 0.005506708345f), make_float3(-0.002887159176f, 0.8640709228f, 4.3593718e-05f), make_float3(-0.001009551548f, -0.01073503317f, 0.6672692039f))
#define matrix_p3_to_p3_d55 make_float3x3(make_float3(0.9559790976f, 0.0403850003f, 0.003639287409f), make_float3(-0.001771929896f, 0.9163058305f, 3.3300759e-05f), make_float3(-0.000674760809f, -0.0072466358f, 0.7831189153f))
#define matrix_p3_to_p3_d60 make_float3x3(make_float3(0.979832881f, 0.01836378979f, 0.001803284786f), make_float3(-0.000805359793f, 0.9618000331f, 1.8876121e-05f), make_float3(-0.000338382322f, -0.003671835795f, 0.894139105f))
#define matrix_p3_to_rec709_d50 make_float3x3(make_float3(1.103807322f, -0.1103425121f, 0.006531676079f), make_float3(-0.04079386701f, 0.8704694227f, -0.000180522628f), make_float3(-0.01854055914f, -0.07857582481f, 0.7105498861f))
#define matrix_p3_to_rec709_d55 make_float3x3(make_float3(1.149327514f, -0.1536910745f, 0.004366526746f), make_float3(-0.0412590771f, 0.9351717477f, -0.000116126221f), make_float3(-0.01900949528f, -0.07928282823f, 0.8437884317f))
#define matrix_p3_to_rec709_d60 make_float3x3(make_float3(1.189986856f, -0.192168414f, 0.002185496045f), make_float3(-0.04168263635f, 0.9927757018f, -5.5660878e-05f), make_float3(-0.01937995127f, -0.07933006919f, 0.9734397041f))
#define matrix_p3_to_rec709_d65 make_float3x3(make_float3(1.224940181f, -0.2249402404f, 0.0f), make_float3(-0.04205697775f, 1.042057037f, -1.4901e-08f), make_float3(-0.01963755488f, -0.07863604277f, 1.098273635f))
#define matrix_p3_to_rec2020 make_float3x3(make_float3(0.7538330344f, 0.1985973691f, 0.04756959659f), make_float3(0.04574384897f, 0.9417772198f, 0.01247893122f), make_float3(-0.001210340355f, 0.0176017173f, 0.9836086231f))




__CONSTANT__ float SQRT3 = 1.73205080756887729353f;
__CONSTANT__ float PI =  3.14159265358979323846;

typedef struct {
  float3 x, y, z;
} dctl_float3x3;


__DEVICE__ dctl_float3x3 make_float3x3(float3 a, float3 b, float3 c) {
  dctl_float3x3 d;
  d.x = a, d.y = b, d.z = c;
  return d;
}


__DEVICE__ dctl_float3x3 identity() {
  return make_float3x3(make_float3(1.0f, 0.0f, 0.0f), make_float3(0.0f, 1.0f, 0.0f), make_float3(0.0f, 0.0f, 1.0f));
}


__DEVICE__ float3 vdot(dctl_float3x3 m, float3 v) {
  return make_float3(m.x.x*v.x + m.x.y*v.y + m.x.z*v.z, m.y.x*v.x + m.y.y*v.y + m.y.z*v.z, m.z.x*v.x + m.z.y*v.y + m.z.z*v.z);
}


__DEVICE__ float sdivf(float a, float b) {
  if (b == 0.0f) return 0.0f;
  else return a/b;
}


__DEVICE__ float3 sdivf3f(float3 a, float b) {
  return make_float3(sdivf(a.x, b), sdivf(a.y, b), sdivf(a.z, b));
}


__DEVICE__ float3 sdivf3f3(float3 a, float3 b) {
  return make_float3(sdivf(a.x, b.x), sdivf(a.y, b.y), sdivf(a.z, b.z));
}


__DEVICE__ float spowf(float a, float b) {
  if (a <= 0.0f) return a;
  else return _powf(a, b);
}


__DEVICE__ float3 spowf3(float3 a, float b) {
  return make_float3(spowf(a.x, b), spowf(a.y, b), spowf(a.z, b));
}


__DEVICE__ float hypotf3(float3 a) { return _sqrtf(a.x*a.x + a.y*a.y + a.z*a.z); }


__DEVICE__ float fmaxf3(float3 a) { return _fmaxf(a.x, _fmaxf(a.y, a.z)); }


__DEVICE__ float fminf3(float3 a) { return _fminf(a.x, _fminf(a.y, a.z)); }


__DEVICE__ float3 clampmaxf3(float3 a, float mx) { return make_float3(_fminf(a.x, mx), _fminf(a.y, mx), _fminf(a.z, mx)); }


__DEVICE__ float3 clampminf3(float3 a, float mn) { return make_float3(_fmaxf(a.x, mn), _fmaxf(a.y, mn), _fmaxf(a.z, mn)); }


__DEVICE__ float clampf(float a, float mn, float mx) { return _fminf(_fmaxf(a, mn), mx); }
__DEVICE__ float3 clampf3(float3 a, float mn, float mx) { return make_float3(clampf(a.x, mn, mx), clampf(a.y, mn, mx), clampf(a.z, mn, mx)); }




__DEVICE__ float oetf_davinci_intermediate(float x) {
    return x <= 0.02740668f ? x/10.44426855f : _exp2f(x/0.07329248f - 7.0f) - 0.0075f;
}
__DEVICE__ float oetf_filmlight_tlog(float x) {
  return x < 0.075f ? (x-0.075f)/16.184376489665897f : _expf((x - 0.5520126568606655f)/0.09232902596577353f) - 0.0057048244042473785f;
}
__DEVICE__ float oetf_acescct(float x) {
  return x <= 0.155251141552511f ? (x - 0.0729055341958355f)/10.5402377416545f : _exp2f(x*17.52f - 9.72f);
}
__DEVICE__ float oetf_arri_logc3(float x) {
  return x < 5.367655f*0.010591f + 0.092809f ? (x - 0.092809f)/5.367655f : (_exp10f((x - 0.385537f)/0.247190f) - 0.052272f)/5.555556f;
}
__DEVICE__ float oetf_arri_logc4(float x) {
  return x < -0.7774983977293537f ? x*0.3033266726886969f - 0.7774983977293537f : (_exp2f(14.0f*(x - 0.09286412512218964f)/0.9071358748778103f + 6.0f) - 64.0f)/2231.8263090676883f;
}
__DEVICE__ float oetf_red_log3g10(float x) {
  return x < 0.0f ? (x/15.1927f) - 0.01f : (_exp10f(x/0.224282f) - 1.0f)/155.975327f - 0.01f;
}
__DEVICE__ float oetf_panasonic_vlog(float x) {
  return x < 0.181f ? (x - 0.125f)/5.6f : _exp10f((x - 0.598206f)/0.241514f) - 0.00873f;
}
__DEVICE__ float oetf_sony_slog3(float x) {
  return x < 171.2102946929f/1023.0f ? (x*1023.0f - 95.0f)*0.01125f/(171.2102946929f - 95.0f) : (_exp10f(((x*1023.0f - 420.0f)/261.5f))*(0.18f + 0.01f) - 0.01f);
}
__DEVICE__ float oetf_fujifilm_flog2(float x) {
  return x < 0.100686685370811f ? (x - 0.092864f)/8.799461f : (_exp10f(((x - 0.384316f)/0.245281f))/5.555556f - 0.064829f/5.555556f);
}

__DEVICE__ float3 linearize(float3 rgb, int tf) {
  if (tf==0) { 
    return rgb;
  } else if (tf==1) { 
    rgb.x = oetf_davinci_intermediate(rgb.x);
    rgb.y = oetf_davinci_intermediate(rgb.y);
    rgb.z = oetf_davinci_intermediate(rgb.z);
  } else if (tf==2) { 
    rgb.x = oetf_filmlight_tlog(rgb.x);
    rgb.y = oetf_filmlight_tlog(rgb.y);
    rgb.z = oetf_filmlight_tlog(rgb.z);
  } else if (tf==3) { 
    rgb.x = oetf_acescct(rgb.x);
    rgb.y = oetf_acescct(rgb.y);
    rgb.z = oetf_acescct(rgb.z);
  } else if (tf==4) { 
    rgb.x = oetf_arri_logc3(rgb.x);
    rgb.y = oetf_arri_logc3(rgb.y);
    rgb.z = oetf_arri_logc3(rgb.z);
  } else if (tf==5) { 
    rgb.x = oetf_arri_logc4(rgb.x);
    rgb.y = oetf_arri_logc4(rgb.y);
    rgb.z = oetf_arri_logc4(rgb.z);
  } else if (tf==6) { 
    rgb.x = oetf_red_log3g10(rgb.x);
    rgb.y = oetf_red_log3g10(rgb.y);
    rgb.z = oetf_red_log3g10(rgb.z);
  } else if (tf==7) { 
    rgb.x = oetf_panasonic_vlog(rgb.x);
    rgb.y = oetf_panasonic_vlog(rgb.y);
    rgb.z = oetf_panasonic_vlog(rgb.z);
  } else if (tf==8) { 
    rgb.x = oetf_sony_slog3(rgb.x);
    rgb.y = oetf_sony_slog3(rgb.y);
    rgb.z = oetf_sony_slog3(rgb.z);
  } else if (tf==9) { 
    rgb.x = oetf_fujifilm_flog2(rgb.x);
    rgb.y = oetf_fujifilm_flog2(rgb.y);
    rgb.z = oetf_fujifilm_flog2(rgb.z);
  }  return rgb;
}





__DEVICE__ float3 eotf_hlg(float3 rgb, int inverse) {
  




  if (inverse == 1) {
    
    
    
    
    
    
    float Yd = 0.2627f*rgb.x + 0.6780f*rgb.y + 0.0593f*rgb.z;
    rgb = rgb*spowf(Yd, (1.0f - 1.2f)/1.2f);
    rgb.x = rgb.x <= 1.0f/12.0f ? _sqrtf(_fmaxf(3.0f*rgb.x, 0.0f)) : 0.17883277f*_logf(12.0f*rgb.x - 0.28466892f) + 0.55991073f;
    rgb.y = rgb.y <= 1.0f/12.0f ? _sqrtf(_fmaxf(3.0f*rgb.y, 0.0f)) : 0.17883277f*_logf(12.0f*rgb.y - 0.28466892f) + 0.55991073f;
    rgb.z = rgb.z <= 1.0f/12.0f ? _sqrtf(_fmaxf(3.0f*rgb.z, 0.0f)) : 0.17883277f*_logf(12.0f*rgb.z - 0.28466892f) + 0.55991073f;
  } else {
    rgb.x = rgb.x <= 0.5f ? rgb.x*rgb.x/3.0f : (_expf((rgb.x - 0.55991073f)/0.17883277f) + 0.28466892f)/12.0f;
    rgb.y = rgb.y <= 0.5f ? rgb.y*rgb.y/3.0f : (_expf((rgb.y - 0.55991073f)/0.17883277f) + 0.28466892f)/12.0f;
    rgb.z = rgb.z <= 0.5f ? rgb.z*rgb.z/3.0f : (_expf((rgb.z - 0.55991073f)/0.17883277f) + 0.28466892f)/12.0f;
    float Ys = 0.2627f*rgb.x + 0.6780f*rgb.y + 0.0593f*rgb.z;
    rgb = rgb*spowf(Ys, 1.2f - 1.0f);
  }
  return rgb;
}


__DEVICE__ float3 eotf_pq(float3 rgb, int inverse) {
  






  const float m1 = 2610.0f/16384.0f;
  const float m2 = 2523.0f/32.0f;
  const float c1 = 107.0f/128.0f;
  const float c2 = 2413.0f/128.0f;
  const float c3 = 2392.0f/128.0f;

  if (inverse == 1) {
    
    
    
    
    
    rgb = clampminf3(rgb, 0.0f);
    rgb = spowf3(rgb, m1);
    rgb = spowf3((c1 + c2*rgb)/(1.0f + c3*rgb), m2);
  } else {
    rgb = spowf3(rgb, 1.0f/m2);
    rgb = spowf3((rgb - c1)/(c2 - c3*rgb), 1.0f/m1);
  }
  return rgb;
}




__DEVICE__ float compress_hyperbolic_power(float x, float s, float p) {
  
  return spowf(x/(x + s), p);
}

__DEVICE__ float compress_toe_quadratic(float x, float toe, int inv) {
  
  if (toe == 0.0f) return x;
  if (inv == 0) {
    return spowf(x, 2.0f)/(x + toe);
  } else {
    return (x + _sqrtf(x*(4.0f*toe + x)))/2.0f;
  }
}

__DEVICE__ float compress_toe_cubic(float x, float m, float w, int inv) {
  
  if (m==1.0f) return x;
  float x2 = x*x;
  if (inv == 0) {
    return x*(x2 + m*w)/(x2 + w);
  } else {
    float p0 = x2 - 3.0f*m*w;
    float p1 = 2.0f*x2 + 27.0f*w - 9.0f*m*w;
    float p2 = _powf(_sqrtf(x2*p1*p1 - 4*p0*p0*p0)/2.0f + x*p1/2.0f, 1.0f/3.0f);
    return p0/(3.0f*p2) + p2/3.0f + x/3.0f;
  }
}

__DEVICE__ float complement_power(float x, float p) {
  return 1.0f - spowf(1.0f - x, 1.0f/p);
}

__DEVICE__ float sigmoid_cubic(float x, float s) {
  
  if (x < 0.0f || x > 1.0f) return 1.0f;
  return 1.0f + s*(1.0f - 3.0f*x*x + 2.0f*x*x*x);
}

__DEVICE__ float contrast_high(float x, float p, float pv, float pv_lx, int inv) {
  
  
  const float x0 = 0.18f*_powf(2.0f, pv);
  if (x < x0 || p == 1.0f) return x;

  const float o = x0 - x0/p;
  const float s0 = _powf(x0, 1.0f - p)/p;
  const float x1 = x0*_powf(2.0f, pv_lx);
  const float k1 = p*s0*_powf(x1, p)/x1;
  const float y1 = s0*_powf(x1, p) + o;
  if (inv==1)
    return x > y1 ? (x - y1)/k1 + x1 : _powf((x - o)/s0, 1.0f/p);
  else
    return x > x1 ? k1*(x - x1) + y1 : s0*_powf(x, p) + o;
}

__DEVICE__ float softplus_constraint(float x, float s, float x0, float y0) {
  
  
  if (x > 10.0f*s + y0 || s < 1e-3f) return x;
  float m = 1.0f;
  if (_fabs(y0) > 1e-6f) m = _expf(y0/s);
  m -= _expf(x0/s);
  return s*_logf(_fmaxf(0.0f, m + _expf(x/s)));
}




__DEVICE__ float smooth_max2(float a, float b, float k) {
  const float h = _fmaxf(k - _fabs(a - b), 0.0f)/k;
  return _fmaxf(a, b) + h*h*k*0.25f;
}
__DEVICE__ float smooth_min2(float a, float b, float k) {
  const float h = _fmaxf(k - _fabs(a - b), 0.0f)/k;
  return _fminf(a, b) - h*h*k*0.25f;
}




__DEVICE__ float smooth_relu(float y, float w) {
  if (y <= 0.0f) return 0.0f;
  if (y >= w) return y;
  return y*y*(2.0f*w - y)/(w*w);
}

__DEVICE__ float softplus(float x, float s) {
  
  
  if (x > 10.0f*s || s < 1e-3f) return x;
  return s*_logf(_fmaxf(0.0f, 1.0f + _expf(x/s)));
}

__DEVICE__ float gauss_window(float x, float w) {
  
  x /= w;
  return _expf(-x*x);
}


__DEVICE__ float hue_offset(float h, float o) {
  
  return _fmod(h - o + PI, 2.0*PI) - PI;
}
















__DEVICE__ float di_encode(float x) {
  return x <= 0.00262409f ? x*10.44426855f
                          : (_log2f(x + 0.0075f) + 7.0f)*0.07329248f;
}

__DEVICE__ float roll_contrast(float x, float f, float pv) {
  const float p2 = 1.0f - pv;
  return x <= pv ? _powf(_fmaxf(x/pv, 1e-10f), f)*pv
                 : 1.0f - _powf(_fmaxf((1.0f - x)/p2, 1e-10f), f)*p2;
}
























__DEVICE__ float con_scene(float x, float f, float pv) {
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  const float dt = 1.486932f;
  const float sg = x < 0.0f ? -1.0f : 1.0f;
  const float d = _fminf(di_encode(_fabs(x))/dt, 1.0f);
  const float p = clampf(pv/dt, 1e-4f, 0.9999f);
  
  
  
  
  
  
  
  
  if (f < 1.0f) {
    const float d0 = _fminf(0.0336f/dt, 0.5f*p);
    if (d < d0) {
      const float v0 = roll_contrast(d0, f, p), s0 = f*v0/d0;
      const float qb = (s0*d0 - v0)/(d0*d0), qa = (2.0f*v0 - s0*d0)/d0;
      return sg*oetf_davinci_intermediate((qa*d + qb*d*d)*dt);
    }
  }
  return sg*oetf_davinci_intermediate(roll_contrast(d, f, p)*dt);
}












#define OVL_CGAIN 1.8f


__DEVICE__ float f_overlay_self(float b) {
  return b <= 0.5f ? 2.0f*b*b : 1.0f - 2.0f*(1.0f - b)*(1.0f - b);
}










__DEVICE__ float3 ovl_limit_chroma(float3 c, float3 r, float gmax) {
  if (gmax >= 2.999f) return r;
  const float Lc = 0.2126f*c.x + 0.7152f*c.y + 0.0722f*c.z;
  const float Lr = 0.2126f*r.x + 0.7152f*r.y + 0.0722f*r.z;
  const float3 vc = make_float3(c.x - Lc, c.y - Lc, c.z - Lc);
  const float3 vr = make_float3(r.x - Lr, r.y - Lr, r.z - Lr);
  const float mc = _sqrtf(vc.x*vc.x + vc.y*vc.y + vc.z*vc.z);
  const float mr = _sqrtf(vr.x*vr.x + vr.y*vr.y + vr.z*vr.z);
  if (mc < 1.0e-5f || mr < 1.0e-9f) return r;   
  const float g = mr/mc;
  if (g <= 1.0f) return r;
  const float range = gmax - 1.0f;
  const float e = g - 1.0f;
  const float gl = 1.0f + range*e/(range + e);  
  const float k = gl/g;
  return make_float3(Lr + vr.x*k, Lr + vr.y*k, Lr + vr.z*k);
}

__DEVICE__ float3 overlay_scene(float3 rgb, float amt, float gmax) {
  
  
  
  const float sx = rgb.x < 0.0f ? -1.0f : 1.0f;
  const float sy = rgb.y < 0.0f ? -1.0f : 1.0f;
  const float sz = rgb.z < 0.0f ? -1.0f : 1.0f;
  float3 lg = make_float3(di_encode(_fabs(rgb.x)), di_encode(_fabs(rgb.y)), di_encode(_fabs(rgb.z)));
  float3 r  = make_float3(f_overlay_self(lg.x), f_overlay_self(lg.y), f_overlay_self(lg.z));
  r = ovl_limit_chroma(lg, r, gmax);
  lg = make_float3(lg.x + (r.x - lg.x)*amt,
                   lg.y + (r.y - lg.y)*amt,
                   lg.z + (r.z - lg.z)*amt);
  return make_float3(sx*oetf_davinci_intermediate(lg.x),
                     sy*oetf_davinci_intermediate(lg.y),
                     sz*oetf_davinci_intermediate(lg.z));
}














__DEVICE__ dctl_float3x3 mat3_mul(dctl_float3x3 a, dctl_float3x3 b) {
  return make_float3x3(
    make_float3(a.x.x*b.x.x + a.x.y*b.y.x + a.x.z*b.z.x,
                a.x.x*b.x.y + a.x.y*b.y.y + a.x.z*b.z.y,
                a.x.x*b.x.z + a.x.y*b.y.z + a.x.z*b.z.z),
    make_float3(a.y.x*b.x.x + a.y.y*b.y.x + a.y.z*b.z.x,
                a.y.x*b.x.y + a.y.y*b.y.y + a.y.z*b.z.y,
                a.y.x*b.x.z + a.y.y*b.y.z + a.y.z*b.z.z),
    make_float3(a.z.x*b.x.x + a.z.y*b.y.x + a.z.z*b.z.x,
                a.z.x*b.x.y + a.z.y*b.y.y + a.z.z*b.z.y,
                a.z.x*b.x.z + a.z.y*b.y.z + a.z.z*b.z.z));
}

__DEVICE__ dctl_float3x3 mat3_inv(dctl_float3x3 m) {
  const float a = m.x.x, b = m.x.y, c = m.x.z;
  const float d = m.y.x, e = m.y.y, f = m.y.z;
  const float g = m.z.x, h = m.z.y, i = m.z.z;
  const float A =  (e*i - f*h), B = -(d*i - f*g), C =  (d*h - e*g);
  float det = a*A + b*B + c*C;
  det = (_fabs(det) < 1.0e-12f) ? (det < 0.0f ? -1.0e-12f : 1.0e-12f) : det;
  const float id = 1.0f/det;
  return make_float3x3(
    make_float3( A*id, -(b*i - c*h)*id,  (b*f - c*e)*id),
    make_float3( B*id,  (a*i - c*g)*id, -(a*f - c*d)*id),
    make_float3( C*id, -(a*h - b*g)*id,  (a*e - b*d)*id));
}

__DEVICE__ float2 wb_planckian_xy(float T) {
  T = clampf(T, 1667.0f, 25000.0f);
  const float T2 = T*T, T3 = T2*T;
  float xc = (T <= 4000.0f)
    ? -0.2661239e9f/T3 - 0.2343589e6f/T2 + 0.8776956e3f/T + 0.179910f
    : -3.0258469e9f/T3 + 2.1070379e6f/T2 + 0.2226347e3f/T + 0.240390f;
  const float x2 = xc*xc, x3 = x2*xc;
  float yc;
  if (T <= 2222.0f)      yc = -1.1063814f*x3 - 1.34811020f*x2 + 2.18555832f*xc - 0.20219683f;
  else if (T <= 4000.0f) yc = -0.9549476f*x3 - 1.37418593f*x2 + 2.09137015f*xc - 0.16748867f;
  else                   yc =  3.0817580f*x3 - 5.87338670f*x2 + 3.75112997f*xc - 0.37001483f;
  return make_float2(xc, yc);
}

__DEVICE__ float2 wb_daylight_xy(float T) {
  T = clampf(T, 4000.0f, 25000.0f);
  const float T2 = T*T, T3 = T2*T;
  const float xD = (T <= 7000.0f)
    ? 0.244063f + 0.09911e3f/T + 2.9678e6f/T2 - 4.6070e9f/T3
    : 0.237040f + 0.24748e3f/T + 1.9018e6f/T2 - 2.0064e9f/T3;
  return make_float2(xD, -3.0f*xD*xD + 2.870f*xD - 0.275f);
}

__DEVICE__ float2 wb_locus_xy(float T) {
  if (T < 3900.0f) return wb_planckian_xy(T);
  if (T > 4100.0f) return wb_daylight_xy(T);
  float t = (T - 3900.0f)/200.0f;
  t = t*t*(3.0f - 2.0f*t);
  const float2 pk = wb_planckian_xy(T);
  const float2 dl = wb_daylight_xy(T);
  return make_float2(pk.x*(1.0f - t) + dl.x*t, pk.y*(1.0f - t) + dl.y*t);
}

__DEVICE__ float2 wb_xy_to_uv(float2 xy) {
  float d = -2.0f*xy.x + 12.0f*xy.y + 3.0f;
  d = (_fabs(d) < 1.0e-10f) ? 1.0e-10f : d;
  return make_float2(4.0f*xy.x/d, 6.0f*xy.y/d);
}

__DEVICE__ float2 wb_uv_to_xy(float2 uv) {
  float d = 2.0f*uv.x - 8.0f*uv.y + 4.0f;
  d = (_fabs(d) < 1.0e-10f) ? 1.0e-10f : d;
  return make_float2(3.0f*uv.x/d, 2.0f*uv.y/d);
}










__DEVICE__ float2 wb_locus_normal_uv(float T) {
  const float2 uvA = wb_xy_to_uv(wb_planckian_xy(_fmaxf(T - 50.0f, 1667.0f)));
  const float2 uvB = wb_xy_to_uv(wb_planckian_xy(_fminf(T + 50.0f, 25000.0f)));
  float tx = uvB.x - uvA.x, ty = uvB.y - uvA.y;
  const float tl = _sqrtf(_fmaxf(tx*tx + ty*ty, 1.0e-12f));
  tx /= tl; ty /= tl;
  float nx = -ty, ny = tx;
  if (ny < 0.0f) { nx = -nx; ny = -ny; }
  return make_float2(nx, ny);
}

__DEVICE__ float2 wb_white_xy(float T, float duv) {
  const float2 xy0 = wb_locus_xy(T);
  if (_fabs(duv) < 1.0e-7f) return xy0;
  const float2 uv0 = wb_xy_to_uv(xy0);
  const float2 n = wb_locus_normal_uv(T);
  return wb_uv_to_xy(make_float2(uv0.x + duv*n.x, uv0.y + duv*n.y));
}

__DEVICE__ float3 wb_xy_to_XYZ(float2 xy) {
  const float y = _fmaxf(xy.y, 1.0e-6f);
  return make_float3(xy.x/y, 1.0f, (1.0f - xy.x - xy.y)/y);
}

__DEVICE__ float3 wb_lms(float3 xyz) {
  return make_float3( 0.8951f*xyz.x + 0.2664f*xyz.y - 0.1614f*xyz.z,
                     -0.7502f*xyz.x + 1.7135f*xyz.y + 0.0367f*xyz.z,
                      0.0389f*xyz.x - 0.0685f*xyz.y + 1.0296f*xyz.z);
}










__DEVICE__ dctl_float3x3 wb_cat(float3 w_src, float3 w_dst) {
  const float3 ls = wb_lms(w_src), ld = wb_lms(w_dst);
  const float gx = ld.x/_fmaxf(ls.x, 0.02f*_fabs(ld.x));
  const float gy = ld.y/_fmaxf(ls.y, 0.02f*_fabs(ld.y));
  const float gz = ld.z/_fmaxf(ls.z, 0.02f*_fabs(ld.z));
  const dctl_float3x3 M = make_float3x3(
    make_float3( 0.8951f,  0.2664f, -0.1614f),
    make_float3(-0.7502f,  1.7135f,  0.0367f),
    make_float3( 0.0389f, -0.0685f,  1.0296f));
  const dctl_float3x3 Mi = make_float3x3(
    make_float3( 0.9869929f, -0.1470543f,  0.1599627f),
    make_float3( 0.4323053f,  0.5183603f,  0.0492912f),
    make_float3(-0.0085287f,  0.0400428f,  0.9684867f));
  const dctl_float3x3 G = make_float3x3(make_float3(gx, 0.0f, 0.0f),
                                   make_float3(0.0f, gy, 0.0f),
                                   make_float3(0.0f, 0.0f, gz));
  return mat3_mul(Mi, mat3_mul(G, M));
}

__DEVICE__ float wb_preset_kelvin(int i) {
  if (i == 1)  return 1800.0f;
  if (i == 2)  return 2400.0f;
  if (i == 3)  return 2700.0f;
  if (i == 4)  return 3200.0f;
  if (i == 5)  return 3600.0f;
  if (i == 6)  return 4000.0f;
  if (i == 7)  return 4300.0f;
  if (i == 8)  return 4800.0f;
  if (i == 9)  return 5000.0f;
  if (i == 10) return 5600.0f;
  if (i == 11) return 6000.0f;
  if (i == 12) return 6500.0f;
  if (i == 13) return 7000.0f;
  if (i == 14) return 7500.0f;
  if (i == 15) return 8500.0f;
  if (i == 16) return 10000.0f;
  return 12000.0f;
}

















__DEVICE__ float smootherstep(float e0, float e1, float x) {
    float t = _clampf((x - e0) / _fmaxf(e1 - e0, 1e-6f), 0.0f, 1.0f);
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

#define DEN_FOG    0.0075f     
#define DEN_LOG018 -2.41503750f 





#define DEN_WIDTH  4.0f        
#define DEN_MAX    0.70f       




































#define DEN_WK     1.283f       
#define DEN_KC     1.20f       




























#define DEN_GK     6.0f        

__DEVICE__ float den_gate(float d, float r) {
  const float q = d/_fmaxf(r, 1.0e-6f);
  const float q2 = q*q;
  return q2/(1.0f + q2);
}


__DEVICE__ float3 density_pair(float3 rgb, float w, float dc) {
  const float xr = _log2f(_fmaxf(rgb.x + DEN_FOG, 1.0e-10f));
  const float xg = _log2f(_fmaxf(rgb.y + DEN_FOG, 1.0e-10f));
  const float xb = _log2f(_fmaxf(rgb.z + DEN_FOG, 1.0e-10f));
  const float m  = (xr + xg + xb)/3.0f;
  const float ev = m - DEN_LOG018;

  float dm = 0.0f;

  
  
  
  
  
  
  
  
  
  
  if (w != 0.0f) {
    
    
    const float yr = _log2f(_fmaxf(rgb.x, 1.0e-10f));
    const float yg = _log2f(_fmaxf(rgb.y, 1.0e-10f));
    const float yb = _log2f(_fmaxf(rgb.z, 1.0e-10f));
    const float u = (2.0f*yr - yg - yb)*0.40824829f;   
    const float v = (yg - yb)*0.70710678f;             
    const float c = _sqrtf(u*u + v*v);
    
    
    
    const float cs = c/(c + DEN_KC);
    
    
    const float s = _fmaxf(rgb.x + rgb.y + rgb.z, 0.0f)/(3.0f*DEN_FOG);
    dm -= DEN_WK*w*cs*den_gate(s, DEN_GK);
  }

  
  
  
  
  
  
  if (dc != 0.0f) {
    const float z = ev/DEN_WIDTH;
    dm += DEN_MAX*dc*z/_sqrtf(1.0f + z*z);
  }

  if (dm == 0.0f) return rgb;
  const float g = _exp2f(dm);
  
  
  return make_float3((rgb.x + DEN_FOG)*g - DEN_FOG,
                     (rgb.y + DEN_FOG)*g - DEN_FOG,
                     (rgb.z + DEN_FOG)*g - DEN_FOG);
}





















































#define MP_MAX  0.62f   
#define MP_KC   0.55f   
#define MP_CUT  0.55f   
#define MP_HW   3.5f    

__DEVICE__ float3 mid_purity(float3 rgb, float a, float pivot) {
  

  const float ev = (_log2f(_fmaxf(rgb.x + DEN_FOG, 1.0e-10f)) +
                    _log2f(_fmaxf(rgb.y + DEN_FOG, 1.0e-10f)) +
                    _log2f(_fmaxf(rgb.z + DEN_FOG, 1.0e-10f)))/3.0f - DEN_LOG018;

  const float t = (ev - pivot)/MP_HW;
  if (t <= -1.0f || t >= 1.0f) return rgb;       
  const float u = 1.0f - t*t;
  const float w = u*u;                            
  if (w <= 0.0f) return rgb;

  
  const float xr = _log2f(_fmaxf(rgb.x, 1.0e-10f));
  const float xg = _log2f(_fmaxf(rgb.y, 1.0e-10f));
  const float xb = _log2f(_fmaxf(rgb.z, 1.0e-10f));
  const float m  = (xr + xg + xb)/3.0f;
  const float dr = xr - m, dg = xg - m, db = xb - m;   
  const float c  = _sqrtf(dr*dr + dg*dg + db*db);
  if (c <= 1.0e-7f) return rgb;                  

  

  const float aw = a*w;
  const float k = aw > 0.0f ? 1.0f + MP_MAX*aw/(c + MP_KC)
                            : 1.0f + MP_CUT*aw;
  if (k == 1.0f) return rgb;

  














  
  
  
  
  
  const float xspan = _fmaxf(xr, _fmaxf(xg, xb)) - _fminf(xr, _fminf(xg, xb));
  const float xw = 0.25f*xspan + 1.0e-12f;
  const float xm = smooth_max2(smooth_max2(xr, xg, xw), xb, xw);
  (void)m; (void)dr; (void)dg; (void)db;
  return make_float3(_exp2f(xm + (xr - xm)*k),
                     _exp2f(xm + (xg - xm)*k),
                     _exp2f(xm + (xb - xm)*k));
}












__DEVICE__ float3 chroma_sub(float3 c, float k) {
  
  
  
  
  
  
  const float bk = 0.25f*(_fmaxf(c.x, _fmaxf(c.y, c.z)) - _fminf(c.x, _fminf(c.y, c.z))) + 1.0e-12f;
  const float base = smooth_max2(smooth_max2(c.x, c.y, bk), c.z, bk);
  if (base <= 0.0f) return c;
  const float kk = _fmaxf(k, 0.0f);
  const float k1 = _fminf(kk, 1.0f);
  const float ke = _fmaxf(kk - 1.0f, 0.0f);
  float3 o;
  for (int i = 0; i < 3; ++i) {
    const float ci = i == 0 ? c.x : (i == 1 ? c.y : c.z);
    const float d  = _fmaxf(base - ci, 0.0f);       
    const float d1 = k1*d;                          
    const float room = _fmaxf(base - d1, 0.0f);     
    const float ex = ke*d;                          
    const float d2 = d1 + (ex > 0.0f ? room*ex/(room + ex) : 0.0f);
    const float v = base - d2;
    if (i == 0) o.x = v; else if (i == 1) o.y = v; else o.z = v;
  }
  return o;
}

__DEVICE__ float soft_sat(float x, float s) {
  float t = clampf(x/s, -8.0f, 8.0f);
  float e = _expf(2.0f*t);
  return s*(e - 1.0f)/(e + 1.0f);
}




__CONSTANT__ float PT_TOP[7][3][97] = {
  {{0.072200f,0.076944f,0.081662f,0.086332f,0.090942f,0.095483f,0.099949f,0.104333f,0.108628f,0.112827f,0.116922f,0.120906f,0.124772f,0.128312f,0.131116f,0.132574f,0.132483f,0.131069f,0.128971f,0.126638f,0.124294f,0.121951f,0.119607f,0.117263f,0.114919f,0.112576f,0.110232f,0.107888f,0.105544f,0.103201f,0.100857f,0.098513f,0.096169f,0.093826f,0.091482f,0.089138f,0.086794f,0.084451f,0.082107f,0.079763f,0.077419f,0.075076f,0.072732f,0.070388f,0.068044f,0.065701f,0.063357f,0.061013f,0.058669f,0.056326f,0.053982f,0.051638f,0.049294f,0.046951f,0.044607f,0.042263f,0.039919f,0.037576f,0.035232f,0.032888f,0.030544f,0.028201f,0.025857f,0.023513f,0.021169f,0.018826f,0.016482f,0.014138f,0.011794f,0.009451f,0.007107f,0.004763f,0.002419f,0.000076f,-0.002268f,-0.004612f,-0.006956f,-0.009299f,-0.011643f,-0.013987f,-0.016331f,-0.018674f,-0.021018f,-0.023362f,-0.025706f,-0.028049f,-0.030393f,-0.032737f,-0.035081f,-0.037424f,-0.039768f,-0.041867f,-0.042656f,-0.040139f,-0.032130f,-0.018086f,0.000000f},
   {0.008653f,0.013136f,0.017604f,0.022043f,0.026443f,0.030797f,0.035097f,0.039336f,0.043507f,0.047601f,0.051611f,0.055529f,0.059347f,0.063058f,0.066653f,0.070123f,0.073380f,0.076146f,0.077963f,0.078438f,0.077579f,0.075774f,0.073544f,0.071200f,0.068856f,0.066512f,0.064169f,0.061825f,0.059481f,0.057137f,0.054794f,0.052450f,0.050106f,0.047762f,0.045419f,0.043075f,0.040731f,0.038387f,0.036044f,0.033700f,0.031356f,0.029012f,0.026669f,0.024325f,0.021981f,0.019637f,0.017294f,0.014950f,0.012606f,0.010262f,0.007919f,0.005575f,0.003231f,0.000887f,-0.001456f,-0.003800f,-0.006144f,-0.008488f,-0.010831f,-0.013175f,-0.015519f,-0.017863f,-0.020206f,-0.022550f,-0.024894f,-0.027238f,-0.029581f,-0.031925f,-0.034269f,-0.036613f,-0.038956f,-0.041300f,-0.043644f,-0.045988f,-0.048331f,-0.050675f,-0.053019f,-0.055363f,-0.057706f,-0.060050f,-0.062394f,-0.064738f,-0.067081f,-0.069425f,-0.071769f,-0.074113f,-0.076456f,-0.078800f,-0.081144f,-0.083359f,-0.084578f,-0.083096f,-0.076655f,-0.064156f,-0.045958f,-0.023918f,0.000000f},
   {-0.071858f,-0.069239f,-0.066648f,-0.064107f,-0.061629f,-0.059223f,-0.056895f,-0.054652f,-0.052590f,-0.050955f,-0.050140f,-0.050411f,-0.051717f,-0.053704f,-0.055981f,-0.058325f,-0.060669f,-0.063013f,-0.065356f,-0.067700f,-0.070044f,-0.072388f,-0.074731f,-0.077075f,-0.079419f,-0.081763f,-0.084106f,-0.086450f,-0.088794f,-0.091138f,-0.093481f,-0.095825f,-0.098169f,-0.100513f,-0.102856f,-0.105200f,-0.107544f,-0.109888f,-0.112231f,-0.114575f,-0.116919f,-0.119263f,-0.121606f,-0.123950f,-0.126294f,-0.128638f,-0.130981f,-0.133325f,-0.135669f,-0.138013f,-0.140356f,-0.142700f,-0.145044f,-0.147388f,-0.149731f,-0.152075f,-0.154419f,-0.156763f,-0.159106f,-0.161450f,-0.163794f,-0.166138f,-0.168481f,-0.170825f,-0.173169f,-0.175513f,-0.177856f,-0.180200f,-0.182544f,-0.184888f,-0.187231f,-0.189575f,-0.191919f,-0.194263f,-0.196606f,-0.198950f,-0.201294f,-0.203638f,-0.205981f,-0.208325f,-0.210669f,-0.213013f,-0.215356f,-0.217700f,-0.220044f,-0.222336f,-0.223764f,-0.222660f,-0.216554f,-0.204194f,-0.185710f,-0.162643f,-0.136015f,-0.106247f,-0.073280f,-0.037493f,0.000000f}},
  {{0.042611f,0.047409f,0.052177f,0.056891f,0.061538f,0.066108f,0.070595f,0.074991f,0.079288f,0.083480f,0.087558f,0.091515f,0.095323f,0.098747f,0.101352f,0.102568f,0.102260f,0.100712f,0.098561f,0.096218f,0.093874f,0.091530f,0.089186f,0.086843f,0.084499f,0.082155f,0.079811f,0.077468f,0.075124f,0.072780f,0.070436f,0.068093f,0.065749f,0.063405f,0.061061f,0.058718f,0.056374f,0.054030f,0.051686f,0.049343f,0.046999f,0.044655f,0.042311f,0.039968f,0.037624f,0.035280f,0.032936f,0.030593f,0.028249f,0.025905f,0.023561f,0.021218f,0.018874f,0.016530f,0.014186f,0.011843f,0.009499f,0.007155f,0.004811f,0.002468f,0.000124f,-0.002220f,-0.004564f,-0.006907f,-0.009251f,-0.011595f,-0.013939f,-0.016282f,-0.018626f,-0.020970f,-0.023314f,-0.025657f,-0.028001f,-0.030345f,-0.032689f,-0.035032f,-0.037376f,-0.039720f,-0.042064f,-0.044407f,-0.046751f,-0.049095f,-0.051439f,-0.053782f,-0.056126f,-0.058470f,-0.060814f,-0.063157f,-0.065501f,-0.067845f,-0.069964f,-0.070780f,-0.068249f,-0.059926f,-0.044849f,-0.023983f,0.000000f},
   {0.023961f,0.028835f,0.033686f,0.038497f,0.043254f,0.047949f,0.052576f,0.057125f,0.061591f,0.065965f,0.070239f,0.074405f,0.078455f,0.082382f,0.086176f,0.089707f,0.092642f,0.094459f,0.094823f,0.093816f,0.091926f,0.089664f,0.087320f,0.084976f,0.082632f,0.080289f,0.077945f,0.075601f,0.073257f,0.070914f,0.068570f,0.066226f,0.063882f,0.061539f,0.059195f,0.056851f,0.054507f,0.052164f,0.049820f,0.047476f,0.045132f,0.042789f,0.040445f,0.038101f,0.035757f,0.033414f,0.031070f,0.028726f,0.026382f,0.024039f,0.021695f,0.019351f,0.017007f,0.014664f,0.012320f,0.009976f,0.007632f,0.005289f,0.002945f,0.000601f,-0.001743f,-0.004086f,-0.006430f,-0.008774f,-0.011118f,-0.013461f,-0.015805f,-0.018149f,-0.020493f,-0.022836f,-0.025180f,-0.027524f,-0.029868f,-0.032211f,-0.034555f,-0.036899f,-0.039243f,-0.041586f,-0.043930f,-0.046274f,-0.048618f,-0.050961f,-0.053305f,-0.055649f,-0.057993f,-0.060336f,-0.062680f,-0.065024f,-0.067368f,-0.069711f,-0.071653f,-0.071968f,-0.068506f,-0.059284f,-0.043746f,-0.023189f,0.000000f},
   {-0.037714f,-0.034320f,-0.030948f,-0.027613f,-0.024326f,-0.021094f,-0.017924f,-0.014823f,-0.011797f,-0.008853f,-0.005997f,-0.003237f,-0.000578f,0.001971f,0.004327f,0.006250f,0.007348f,0.007310f,0.006160f,0.004244f,0.001986f,-0.000358f,-0.002701f,-0.005045f,-0.007389f,-0.009733f,-0.012076f,-0.014420f,-0.016764f,-0.019108f,-0.021451f,-0.023795f,-0.026139f,-0.028483f,-0.030826f,-0.033170f,-0.035514f,-0.037858f,-0.040201f,-0.042545f,-0.044889f,-0.047233f,-0.049576f,-0.051920f,-0.054264f,-0.056608f,-0.058951f,-0.061295f,-0.063639f,-0.065983f,-0.068326f,-0.070670f,-0.073014f,-0.075358f,-0.077701f,-0.080045f,-0.082389f,-0.084733f,-0.087076f,-0.089420f,-0.091764f,-0.094108f,-0.096451f,-0.098795f,-0.101139f,-0.103483f,-0.105826f,-0.108170f,-0.110514f,-0.112858f,-0.115201f,-0.117545f,-0.119889f,-0.122233f,-0.124576f,-0.126920f,-0.129264f,-0.131608f,-0.133951f,-0.136295f,-0.138639f,-0.140983f,-0.143326f,-0.145670f,-0.148014f,-0.150358f,-0.152507f,-0.153642f,-0.152239f,-0.146561f,-0.135850f,-0.120478f,-0.101520f,-0.079631f,-0.055108f,-0.028259f,0.000000f}},
  {{0.087620f,0.092411f,0.097173f,0.101886f,0.106535f,0.111112f,0.115611f,0.120023f,0.124343f,0.128562f,0.132673f,0.136503f,0.139664f,0.141559f,0.141881f,0.140776f,0.138823f,0.136534f,0.134191f,0.131847f,0.129503f,0.127159f,0.124816f,0.122472f,0.120128f,0.117784f,0.115441f,0.113097f,0.110753f,0.108409f,0.106066f,0.103722f,0.101378f,0.099034f,0.096691f,0.094347f,0.092003f,0.089659f,0.087316f,0.084972f,0.082628f,0.080284f,0.077941f,0.075597f,0.073253f,0.070909f,0.068566f,0.066222f,0.063878f,0.061534f,0.059191f,0.056847f,0.054503f,0.052159f,0.049816f,0.047472f,0.045128f,0.042784f,0.040441f,0.038097f,0.035753f,0.033409f,0.031066f,0.028722f,0.026378f,0.024034f,0.021691f,0.019347f,0.017003f,0.014659f,0.012316f,0.009972f,0.007628f,0.005284f,0.002941f,0.000597f,-0.001747f,-0.004091f,-0.006434f,-0.008778f,-0.011122f,-0.013466f,-0.015809f,-0.018153f,-0.020497f,-0.022841f,-0.025184f,-0.027528f,-0.029872f,-0.032216f,-0.034559f,-0.036867f,-0.038275f,-0.036981f,-0.030356f,-0.017429f,0.000000f},
   {0.003691f,0.008314f,0.012920f,0.017497f,0.022034f,0.026523f,0.030958f,0.035330f,0.039631f,0.043855f,0.047993f,0.052037f,0.055979f,0.059812f,0.063526f,0.067114f,0.070525f,0.073518f,0.075663f,0.076482f,0.075898f,0.074227f,0.072039f,0.069695f,0.067352f,0.065008f,0.062664f,0.060320f,0.057977f,0.055633f,0.053289f,0.050945f,0.048602f,0.046258f,0.043914f,0.041570f,0.039227f,0.036883f,0.034539f,0.032195f,0.029852f,0.027508f,0.025164f,0.022820f,0.020477f,0.018133f,0.015789f,0.013445f,0.011102f,0.008758f,0.006414f,0.004070f,0.001727f,-0.000617f,-0.002961f,-0.005305f,-0.007648f,-0.009992f,-0.012336f,-0.014680f,-0.017023f,-0.019367f,-0.021711f,-0.024055f,-0.026398f,-0.028742f,-0.031086f,-0.033430f,-0.035773f,-0.038117f,-0.040461f,-0.042805f,-0.045148f,-0.047492f,-0.049836f,-0.052180f,-0.054523f,-0.056867f,-0.059211f,-0.061555f,-0.063898f,-0.066242f,-0.068586f,-0.070930f,-0.073273f,-0.075617f,-0.077961f,-0.080305f,-0.082648f,-0.084843f,-0.085994f,-0.084361f,-0.077698f,-0.064938f,-0.046479f,-0.024178f,0.000000f},
   {-0.078596f,-0.075989f,-0.073410f,-0.070881f,-0.068413f,-0.066017f,-0.063697f,-0.061462f,-0.059371f,-0.057632f,-0.056601f,-0.056617f,-0.057706f,-0.059583f,-0.061824f,-0.064168f,-0.066511f,-0.068855f,-0.071199f,-0.073543f,-0.075886f,-0.078230f,-0.080574f,-0.082918f,-0.085261f,-0.087605f,-0.089949f,-0.092293f,-0.094636f,-0.096980f,-0.099324f,-0.101668f,-0.104011f,-0.106355f,-0.108699f,-0.111043f,-0.113386f,-0.115730f,-0.118074f,-0.120418f,-0.122761f,-0.125105f,-0.127449f,-0.129793f,-0.132136f,-0.134480f,-0.136824f,-0.139168f,-0.141511f,-0.143855f,-0.146199f,-0.148543f,-0.150886f,-0.153230f,-0.155574f,-0.157918f,-0.160261f,-0.162605f,-0.164949f,-0.167293f,-0.169636f,-0.171980f,-0.174324f,-0.176668f,-0.179011f,-0.181355f,-0.183699f,-0.186043f,-0.188386f,-0.190730f,-0.193074f,-0.195418f,-0.197761f,-0.200105f,-0.202449f,-0.204793f,-0.207136f,-0.209480f,-0.211824f,-0.214168f,-0.216511f,-0.218855f,-0.221199f,-0.223543f,-0.225886f,-0.227956f,-0.228714f,-0.226267f,-0.218590f,-0.204877f,-0.185709f,-0.162414f,-0.135795f,-0.106056f,-0.073138f,-0.037416f,0.000000f}},
  {{0.010262f,0.015533f,0.020771f,0.025948f,0.031048f,0.036062f,0.040982f,0.045801f,0.050510f,0.055101f,0.059566f,0.063898f,0.068070f,0.071838f,0.074748f,0.076192f,0.076021f,0.074530f,0.072393f,0.070049f,0.067706f,0.065362f,0.063018f,0.060674f,0.058331f,0.055987f,0.053643f,0.051299f,0.048956f,0.046612f,0.044268f,0.041924f,0.039581f,0.037237f,0.034893f,0.032549f,0.030206f,0.027862f,0.025518f,0.023174f,0.020831f,0.018487f,0.016143f,0.013799f,0.011456f,0.009112f,0.006768f,0.004424f,0.002081f,-0.000263f,-0.002607f,-0.004951f,-0.007294f,-0.009638f,-0.011982f,-0.014326f,-0.016669f,-0.019013f,-0.021357f,-0.023701f,-0.026044f,-0.028388f,-0.030732f,-0.033076f,-0.035419f,-0.037763f,-0.040107f,-0.042451f,-0.044794f,-0.047138f,-0.049482f,-0.051826f,-0.054169f,-0.056513f,-0.058857f,-0.061201f,-0.063544f,-0.065888f,-0.068232f,-0.070576f,-0.072919f,-0.075263f,-0.077607f,-0.079951f,-0.082294f,-0.084638f,-0.086982f,-0.089326f,-0.091669f,-0.093992f,-0.095426f,-0.094149f,-0.087331f,-0.073483f,-0.052788f,-0.027509f,0.000000f},
   {0.064446f,0.069128f,0.073771f,0.078345f,0.082832f,0.087222f,0.091508f,0.095682f,0.099736f,0.103562f,0.106843f,0.109058f,0.109782f,0.109036f,0.107267f,0.105040f,0.102696f,0.100353f,0.098009f,0.095665f,0.093321f,0.090978f,0.088634f,0.086290f,0.083946f,0.081603f,0.079259f,0.076915f,0.074571f,0.072228f,0.069884f,0.067540f,0.065196f,0.062853f,0.060509f,0.058165f,0.055821f,0.053478f,0.051134f,0.048790f,0.046446f,0.044103f,0.041759f,0.039415f,0.037071f,0.034728f,0.032384f,0.030040f,0.027696f,0.025353f,0.023009f,0.020665f,0.018321f,0.015978f,0.013634f,0.011290f,0.008946f,0.006603f,0.004259f,0.001915f,-0.000429f,-0.002772f,-0.005116f,-0.007460f,-0.009804f,-0.012147f,-0.014491f,-0.016835f,-0.019179f,-0.021522f,-0.023866f,-0.026210f,-0.028554f,-0.030897f,-0.033241f,-0.035585f,-0.037929f,-0.040272f,-0.042616f,-0.044960f,-0.047304f,-0.049647f,-0.051991f,-0.054335f,-0.056679f,-0.059022f,-0.061366f,-0.063710f,-0.066054f,-0.068397f,-0.070741f,-0.072287f,-0.071130f,-0.064129f,-0.049302f,-0.026878f,0.000000f},
   {0.085165f,0.089694f,0.094172f,0.098562f,0.102843f,0.107003f,0.111036f,0.114816f,0.118011f,0.120086f,0.120662f,0.119794f,0.117966f,0.115720f,0.113376f,0.111032f,0.108689f,0.106345f,0.104001f,0.101657f,0.099314f,0.096970f,0.094626f,0.092282f,0.089939f,0.087595f,0.085251f,0.082907f,0.080564f,0.078220f,0.075876f,0.073532f,0.071189f,0.068845f,0.066501f,0.064157f,0.061814f,0.059470f,0.057126f,0.054782f,0.052439f,0.050095f,0.047751f,0.045407f,0.043064f,0.040720f,0.038376f,0.036032f,0.033689f,0.031345f,0.029001f,0.026657f,0.024314f,0.021970f,0.019626f,0.017282f,0.014939f,0.012595f,0.010251f,0.007907f,0.005564f,0.003220f,0.000876f,-0.001468f,-0.003811f,-0.006155f,-0.008499f,-0.010843f,-0.013186f,-0.015530f,-0.017874f,-0.020218f,-0.022561f,-0.024905f,-0.027249f,-0.029593f,-0.031936f,-0.034280f,-0.036624f,-0.038968f,-0.041311f,-0.043655f,-0.045999f,-0.048343f,-0.050686f,-0.053030f,-0.055374f,-0.057718f,-0.060061f,-0.062405f,-0.064749f,-0.066712f,-0.066713f,-0.061832f,-0.048956f,-0.027372f,0.000000f}},
  {{0.247712f,0.245368f,0.243025f,0.240681f,0.238337f,0.235993f,0.233650f,0.231306f,0.228962f,0.226618f,0.224275f,0.221931f,0.219587f,0.217243f,0.214900f,0.212556f,0.210212f,0.207868f,0.205525f,0.203181f,0.200837f,0.198493f,0.196150f,0.193806f,0.191462f,0.189118f,0.186775f,0.184431f,0.182087f,0.179743f,0.177400f,0.175056f,0.172712f,0.170368f,0.168025f,0.165681f,0.163337f,0.160993f,0.158650f,0.156306f,0.153962f,0.151618f,0.149275f,0.146931f,0.144587f,0.142243f,0.139900f,0.137556f,0.135212f,0.132868f,0.130525f,0.128181f,0.125837f,0.123493f,0.121150f,0.118806f,0.116462f,0.114118f,0.111775f,0.109431f,0.107087f,0.104743f,0.102400f,0.100056f,0.097712f,0.095368f,0.093025f,0.090681f,0.088337f,0.085993f,0.083650f,0.081306f,0.078962f,0.076618f,0.074275f,0.071931f,0.069587f,0.067243f,0.064900f,0.062556f,0.060212f,0.057868f,0.055525f,0.053181f,0.050837f,0.048493f,0.046150f,0.043806f,0.041462f,0.039118f,0.036775f,0.034431f,0.032087f,0.029743f,0.027400f,0.025056f,0.000000f},
   {0.302263f,0.299919f,0.297576f,0.295232f,0.292888f,0.290544f,0.288201f,0.285857f,0.283513f,0.281169f,0.278826f,0.276482f,0.274138f,0.271794f,0.269451f,0.267107f,0.264763f,0.262419f,0.260076f,0.257732f,0.255388f,0.253044f,0.250701f,0.248357f,0.246013f,0.243669f,0.241326f,0.238982f,0.236638f,0.234294f,0.231951f,0.229607f,0.227263f,0.224919f,0.222576f,0.220232f,0.217888f,0.215544f,0.213201f,0.210857f,0.208513f,0.206169f,0.203826f,0.201482f,0.199138f,0.196794f,0.194451f,0.192107f,0.189763f,0.187419f,0.185076f,0.182732f,0.180388f,0.178044f,0.175701f,0.173357f,0.171013f,0.168669f,0.166326f,0.163982f,0.161638f,0.159294f,0.156951f,0.154607f,0.152263f,0.149919f,0.147576f,0.145232f,0.142888f,0.140544f,0.138201f,0.135857f,0.133513f,0.131169f,0.128826f,0.126482f,0.124138f,0.121794f,0.119451f,0.117107f,0.114763f,0.112419f,0.110076f,0.107732f,0.105388f,0.103044f,0.100701f,0.098357f,0.096013f,0.093669f,0.091326f,0.088982f,0.086638f,0.084294f,0.081951f,0.079607f,0.000000f},
   {0.396322f,0.393978f,0.391634f,0.389291f,0.386947f,0.384603f,0.382259f,0.379916f,0.377572f,0.375228f,0.372884f,0.370541f,0.368197f,0.365853f,0.363509f,0.361166f,0.358822f,0.356478f,0.354134f,0.351791f,0.349447f,0.347103f,0.344759f,0.342416f,0.340072f,0.337728f,0.335384f,0.333041f,0.330697f,0.328353f,0.326009f,0.323666f,0.321322f,0.318978f,0.316634f,0.314291f,0.311947f,0.309603f,0.307259f,0.304916f,0.302572f,0.300228f,0.297884f,0.295541f,0.293197f,0.290853f,0.288509f,0.286166f,0.283822f,0.281478f,0.279134f,0.276791f,0.274447f,0.272103f,0.269759f,0.267416f,0.265072f,0.262728f,0.260384f,0.258041f,0.255697f,0.253353f,0.251009f,0.248666f,0.246322f,0.243978f,0.241634f,0.239291f,0.236947f,0.234603f,0.232259f,0.229916f,0.227572f,0.225228f,0.222884f,0.220541f,0.218197f,0.215853f,0.213509f,0.211166f,0.208822f,0.206478f,0.204134f,0.201791f,0.199447f,0.197103f,0.194759f,0.192416f,0.190072f,0.187728f,0.185384f,0.183041f,0.180697f,0.178353f,0.176009f,0.173666f,0.000000f}},
  {{0.008483f,0.010040f,0.011597f,0.013152f,0.014704f,0.016249f,0.017786f,0.019311f,0.020820f,0.022311f,0.023781f,0.025226f,0.026643f,0.028030f,0.029382f,0.030696f,0.031968f,0.033197f,0.034377f,0.035506f,0.036580f,0.037595f,0.038549f,0.039438f,0.040258f,0.041007f,0.041679f,0.042274f,0.042786f,0.043214f,0.043553f,0.043801f,0.043956f,0.044013f,0.043970f,0.043826f,0.043576f,0.043220f,0.042755f,0.042179f,0.041489f,0.040686f,0.039751f,0.038630f,0.037241f,0.035522f,0.033499f,0.031269f,0.028948f,0.026604f,0.024261f,0.021917f,0.019573f,0.017229f,0.014886f,0.012542f,0.010198f,0.007854f,0.005511f,0.003167f,0.000823f,-0.001521f,-0.003864f,-0.006208f,-0.008552f,-0.010896f,-0.013239f,-0.015583f,-0.017927f,-0.020271f,-0.022614f,-0.024958f,-0.027302f,-0.029646f,-0.031989f,-0.034333f,-0.036677f,-0.039021f,-0.041364f,-0.043708f,-0.046005f,-0.048117f,-0.049802f,-0.050831f,-0.051100f,-0.050654f,-0.049581f,-0.047922f,-0.045655f,-0.042727f,-0.039084f,-0.034671f,-0.029426f,-0.023286f,-0.016230f,-0.008361f,0.000000f},
   {0.012929f,0.013938f,0.014940f,0.015928f,0.016899f,0.017850f,0.018781f,0.019689f,0.020572f,0.021428f,0.022257f,0.023055f,0.023822f,0.024554f,0.025251f,0.025910f,0.026529f,0.027107f,0.027642f,0.028132f,0.028574f,0.028967f,0.029309f,0.029599f,0.029834f,0.030012f,0.030133f,0.030193f,0.030192f,0.030128f,0.029999f,0.029804f,0.029541f,0.029209f,0.028808f,0.028334f,0.027788f,0.027169f,0.026476f,0.025708f,0.024864f,0.023945f,0.022950f,0.021878f,0.020731f,0.019508f,0.018210f,0.016838f,0.015393f,0.013876f,0.012289f,0.010634f,0.008912f,0.007127f,0.005281f,0.003378f,0.001421f,-0.000586f,-0.002638f,-0.004731f,-0.006858f,-0.009014f,-0.011193f,-0.013387f,-0.015589f,-0.017790f,-0.019982f,-0.022154f,-0.024297f,-0.026400f,-0.028450f,-0.030435f,-0.032341f,-0.034154f,-0.035858f,-0.037437f,-0.038874f,-0.040149f,-0.041243f,-0.042135f,-0.042803f,-0.043223f,-0.043371f,-0.043221f,-0.042744f,-0.041911f,-0.040691f,-0.039053f,-0.036961f,-0.034379f,-0.031270f,-0.027594f,-0.023307f,-0.018367f,-0.012758f,-0.006558f,0.000000f},
   {-0.000350f,0.000365f,0.001074f,0.001774f,0.002462f,0.003136f,0.003795f,0.004438f,0.005063f,0.005669f,0.006254f,0.006817f,0.007356f,0.007870f,0.008357f,0.008817f,0.009247f,0.009645f,0.010011f,0.010343f,0.010639f,0.010898f,0.011119f,0.011299f,0.011437f,0.011533f,0.011584f,0.011589f,0.011547f,0.011457f,0.011317f,0.011125f,0.010882f,0.010586f,0.010235f,0.009830f,0.009368f,0.008850f,0.008275f,0.007641f,0.006950f,0.006200f,0.005391f,0.004523f,0.003597f,0.002613f,0.001572f,0.000473f,-0.000681f,-0.001890f,-0.003153f,-0.004467f,-0.005832f,-0.007243f,-0.008700f,-0.010200f,-0.011738f,-0.013312f,-0.014918f,-0.016551f,-0.018206f,-0.019880f,-0.021565f,-0.023256f,-0.024946f,-0.026628f,-0.028295f,-0.029937f,-0.031546f,-0.033113f,-0.034626f,-0.036075f,-0.037449f,-0.038733f,-0.039916f,-0.040982f,-0.041917f,-0.042703f,-0.043325f,-0.043763f,-0.043998f,-0.044010f,-0.043777f,-0.043275f,-0.042481f,-0.041370f,-0.039913f,-0.038082f,-0.035847f,-0.033177f,-0.030037f,-0.026394f,-0.022208f,-0.017443f,-0.012084f,-0.006201f,0.000000f}},
  {{0.062945f,0.067978f,0.072967f,0.077879f,0.082695f,0.087406f,0.092003f,0.096480f,0.100827f,0.105033f,0.108864f,0.111874f,0.113425f,0.113340f,0.111891f,0.109768f,0.107425f,0.105081f,0.102737f,0.100393f,0.098050f,0.095706f,0.093362f,0.091018f,0.088675f,0.086331f,0.083987f,0.081643f,0.079300f,0.076956f,0.074612f,0.072268f,0.069925f,0.067581f,0.065237f,0.062893f,0.060550f,0.058206f,0.055862f,0.053518f,0.051175f,0.048831f,0.046487f,0.044143f,0.041800f,0.039456f,0.037112f,0.034768f,0.032425f,0.030081f,0.027737f,0.025393f,0.023050f,0.020706f,0.018362f,0.016018f,0.013675f,0.011331f,0.008987f,0.006643f,0.004300f,0.001956f,-0.000388f,-0.002732f,-0.005075f,-0.007419f,-0.009763f,-0.012107f,-0.014450f,-0.016794f,-0.019138f,-0.021482f,-0.023825f,-0.026169f,-0.028513f,-0.030857f,-0.033200f,-0.035544f,-0.037888f,-0.040232f,-0.042575f,-0.044919f,-0.047263f,-0.049607f,-0.051950f,-0.054294f,-0.056638f,-0.058982f,-0.061325f,-0.063669f,-0.066013f,-0.067656f,-0.066827f,-0.060561f,-0.046800f,-0.025624f,0.000000f},
   {0.072002f,0.076319f,0.080601f,0.084819f,0.088956f,0.093004f,0.096955f,0.100802f,0.104538f,0.108092f,0.111194f,0.113380f,0.114182f,0.113553f,0.111852f,0.109652f,0.107309f,0.104965f,0.102621f,0.100277f,0.097934f,0.095590f,0.093246f,0.090902f,0.088559f,0.086215f,0.083871f,0.081527f,0.079184f,0.076840f,0.074496f,0.072152f,0.069809f,0.067465f,0.065121f,0.062777f,0.060434f,0.058090f,0.055746f,0.053402f,0.051059f,0.048715f,0.046371f,0.044027f,0.041684f,0.039340f,0.036996f,0.034652f,0.032309f,0.029965f,0.027621f,0.025277f,0.022934f,0.020590f,0.018246f,0.015902f,0.013559f,0.011215f,0.008871f,0.006527f,0.004184f,0.001840f,-0.000504f,-0.002848f,-0.005191f,-0.007535f,-0.009879f,-0.012223f,-0.014566f,-0.016910f,-0.019254f,-0.021598f,-0.023941f,-0.026285f,-0.028629f,-0.030973f,-0.033316f,-0.035660f,-0.038004f,-0.040348f,-0.042691f,-0.045035f,-0.047379f,-0.049723f,-0.052066f,-0.054410f,-0.056754f,-0.059098f,-0.061441f,-0.063785f,-0.066129f,-0.067726f,-0.066780f,-0.060320f,-0.046443f,-0.025346f,0.000000f},
   {0.010525f,0.013413f,0.016274f,0.019088f,0.021843f,0.024532f,0.027149f,0.029689f,0.032146f,0.034515f,0.036789f,0.038890f,0.040589f,0.041513f,0.041363f,0.040157f,0.038221f,0.035960f,0.033616f,0.031272f,0.028929f,0.026585f,0.024241f,0.021897f,0.019554f,0.017210f,0.014866f,0.012522f,0.010179f,0.007835f,0.005491f,0.003147f,0.000804f,-0.001540f,-0.003884f,-0.006228f,-0.008571f,-0.010915f,-0.013259f,-0.015603f,-0.017946f,-0.020290f,-0.022634f,-0.024978f,-0.027321f,-0.029665f,-0.032009f,-0.034353f,-0.036696f,-0.039040f,-0.041384f,-0.043728f,-0.046071f,-0.048415f,-0.050759f,-0.053103f,-0.055446f,-0.057790f,-0.060134f,-0.062478f,-0.064821f,-0.067165f,-0.069509f,-0.071853f,-0.074196f,-0.076540f,-0.078884f,-0.081228f,-0.083571f,-0.085915f,-0.088259f,-0.090603f,-0.092946f,-0.095290f,-0.097634f,-0.099978f,-0.102321f,-0.104665f,-0.107009f,-0.109353f,-0.111696f,-0.114040f,-0.116384f,-0.118728f,-0.121071f,-0.123415f,-0.125759f,-0.127869f,-0.128860f,-0.127109f,-0.120871f,-0.109433f,-0.093268f,-0.073494f,-0.050898f,-0.026112f,0.000000f}}
};

__DEVICE__ float3 print_tone(float tsn, int id, float amt, float lim) {
  const float u = clampf(spowf(tsn, 1.0f/3.6f), 0.0f, 1.0f);
  const float env = (1.0f - u);
  float3 lg = make_float3(0.0f, 0.0f, 0.0f);
  if (id==1) { 
    lg.x = env*(4.81794288f + u*(-71.5952792f + u*(271.11404f + u*(-300.001087f + u*(-169.812019f + u*(300.001644f + u*(257.445947f + u*(-300.007984f))))))));
    lg.y = env*(4.13265061f + u*(-55.4162744f + u*(231.417924f + u*(-283.188122f + u*(-152.292866f + u*(300.002632f + u*(246.154597f + u*(-300.017495f))))))));
    lg.z = env*(3.24557422f + u*(-51.7206987f + u*(230.122185f + u*(-300.001281f + u*(-125.215939f + u*(300.001451f + u*(229.545555f + u*(-300.006082f))))))));
  }
  else if (id==2) { 
    lg.x = env*(3.53640281f + u*(-61.3436501f + u*(251.205781f + u*(-300.000476f + u*(-148.313757f + u*(300.001164f + u*(245.480543f + u*(-300.006435f))))))));
    lg.y = env*(1.80697342f + u*(-28.3333782f + u*(128.134024f + u*(-118.661521f + u*(-253.109922f + u*(300.00308f + u*(261.112738f + u*(-300.019773f))))))));
    lg.z = env*(0.118328352f + u*(-18.8524489f + u*(98.3071484f + u*(-60.9886514f + u*(-300.000034f + u*(298.307815f + u*(272.417549f + u*(-300.00104f))))))));
  }
  else if (id==3) { 
    lg.x = env*(4.15054865f + u*(-67.0463055f + u*(263.188128f + u*(-300.001202f + u*(-162.069489f + u*(300.001777f + u*(253.659258f + u*(-300.008536f))))))));
    lg.y = env*(4.10581688f + u*(-55.4860531f + u*(233.620376f + u*(-291.019276f + u*(-144.18112f + u*(300.002667f + u*(243.670211f + u*(-300.017697f))))))));
    lg.z = env*(3.84248818f + u*(-55.1725072f + u*(235.541366f + u*(-300.001446f + u*(-129.789729f + u*(300.00156f + u*(231.590409f + u*(-300.006381f))))))));
  }
  else if (id==4) { 
    lg.x = env*(4.74437229f + u*(-61.2948162f + u*(242.899839f + u*(-300.006164f + u*(-132.13986f + u*(300.007056f + u*(235.284572f + u*(-300.029157f))))))));
    lg.y = env*(5.36039573f + u*(-63.0707006f + u*(244.451608f + u*(-300.013883f + u*(-130.726678f + u*(300.016088f + u*(233.137881f + u*(-300.067152f))))))));
    lg.z = env*(7.39021266f + u*(-73.3166211f + u*(257.357884f + u*(-300.002756f + u*(-134.479994f + u*(300.003061f + u*(231.206063f + u*(-300.012345f))))))));
  }
  else if (id==5) { 
    lg.x = env*(9.21269594f + u*(-87.2568695f + u*(276.10231f + u*(-300.006741f + u*(-124.711087f + u*(300.006728f + u*(206.737163f + u*(-300.025376f))))))));
    lg.y = env*(5.5912644f + u*(-69.1733067f + u*(251.983639f + u*(-300.014838f + u*(-110.014142f + u*(300.015126f + u*(202.235327f + u*(-300.058031f))))))));
    lg.z = env*(11.401878f + u*(-97.9081792f + u*(293.387244f + u*(-300.00133f + u*(-141.709937f + u*(300.001156f + u*(218.234f + u*(-300.003888f))))))));
  }
  else if (id==6) { 
    lg.x = env*(-17.036161f + u*(75.0012782f + u*(-66.2380399f + u*(-75.000634f + u*(55.547801f + u*(75.0007173f + u*(24.4933467f + u*(-75.0032348f))))))));
    lg.y = env*(2.00638068f + u*(-19.9364656f + u*(68.5388444f + u*(-75.0043493f + u*(-40.4129738f + u*(75.004962f + u*(62.3137434f + u*(-75.0205765f))))))));
    lg.z = env*(2.95869853f + u*(-25.6098124f + u*(75.0008824f + u*(-63.5196209f + u*(-61.3893484f + u*(75.0004029f + u*(70.2066583f + u*(-75.0020002f))))))));
  }
  else if (id==7) { 
    lg.x = env*(5.84156135f + u*(-70.6893669f + u*(259.495625f + u*(-300.008047f + u*(-144.414894f + u*(300.008991f + u*(239.269539f + u*(-300.036682f))))))));
    lg.y = env*(6.86321298f + u*(-73.2499876f + u*(262.96468f + u*(-300.019616f + u*(-149.557305f + u*(300.022072f + u*(242.745558f + u*(-300.090553f))))))));
    lg.z = env*(10.5499108f + u*(-98.5093998f + u*(300.004888f + u*(-268.020022f + u*(-228.638003f + u*(300.002143f + u*(274.718456f + u*(-300.010382f))))))));
  }

  
  
  
  
  
  
  
  
  
  
  
  if (lim > 0.0f && id >= 1 && id <= 7) {
    const float tl = _log2f(_fmaxf(tsn, 1.0e-12f));
    if (tl > -1.5000f && tl < 0.0f) {
      const float p = (tl - (-1.5000f))*64.000000f;
      const int i0 = (int)_fminf(p, 95.0f);
      const int i1 = i0 + 1;
      const float f = p - (float)i0;
      const float3 lt = make_float3(PT_TOP[id-1][0][i0] + (PT_TOP[id-1][0][i1] - PT_TOP[id-1][0][i0])*f,
                                    PT_TOP[id-1][1][i0] + (PT_TOP[id-1][1][i1] - PT_TOP[id-1][1][i0])*f,
                                    PT_TOP[id-1][2][i0] + (PT_TOP[id-1][2][i1] - PT_TOP[id-1][2][i0])*f);
      lg = lg + (lt - lg)*lim;
    }
  }

  
  lg.x *= amt; lg.y *= amt; lg.z *= amt;

  return make_float3(_exp2f(soft_sat(lg.x, 2.5f)),
                     _exp2f(soft_sat(lg.y, 2.5f)),
                     _exp2f(soft_sat(lg.z, 2.5f)));
}











#define SKIN_A 0.614430f
#define SKIN_B 0.788971f





__DEVICE__ float3 ovl_oklab(float3 c) {
  float l = 0.4122214708f*c.x + 0.5363325363f*c.y + 0.0514459929f*c.z;
  float m = 0.2119034982f*c.x + 0.6806995451f*c.y + 0.1073969566f*c.z;
  float t = 0.0883024619f*c.x + 0.2817188376f*c.y + 0.6299787005f*c.z;
  l = _cbrtf(_fmaxf(l, 0.0f)); m = _cbrtf(_fmaxf(m, 0.0f)); t = _cbrtf(_fmaxf(t, 0.0f));
  return make_float3(0.2104542553f*l + 0.7936177850f*m - 0.0040720468f*t,
                     1.9779984951f*l - 2.4285922050f*m + 0.4505937099f*t,
                     0.0259040371f*l + 0.7827717662f*m - 0.8086757660f*t);
}
__DEVICE__ float ovl_band(float v, float lo, float hi) {
  float t = _clampf((v - lo)/_fmaxf(hi - lo, 1e-4f), 0.0f, 1.0f);
  return t*t*(3.0f - 2.0f*t);
}
































__DEVICE__ float3 over_di(float3 dst, float3 src, float a) {
    float k = _clampf(a, 0.0f, 1.0f);
    float3 o;
    o.x = dst.x + k * (src.x - dst.x);
    o.y = dst.y + k * (src.y - dst.y);
    o.z = dst.z + k * (src.z - dst.z);
    return o;
}

__DEVICE__ float sd_rbox(float px, float py, float cx, float cy,
                         float hw, float hh, float r) {
    float qx = _fabs(px - cx) - (hw - r);
    float qy = _fabs(py - cy) - (hh - r);
    float ax = _fmaxf(qx, 0.0f), ay = _fmaxf(qy, 0.0f);
    return _sqrtf(ax * ax + ay * ay) + _fminf(_fmaxf(qx, qy), 0.0f) - r;
}

__DEVICE__ float cov_sdf(float d, float aa) {
    return 1.0f - smootherstep(-aa, aa, d);
}

__DEVICE__ float cov_rect(float px, float py, float x0, float y0,
                          float x1, float y1, float aa) {
    float cx = (x0 + x1) * 0.5f, cy = (y0 + y1) * 0.5f;
    float hw = (x1 - x0) * 0.5f, hh = (y1 - y0) * 0.5f;
    float d  = _fmaxf(_fabs(px - cx) - hw, _fabs(py - cy) - hh);
    return 1.0f - smootherstep(-aa, aa, d);
}



#define C_SP   0
#define C_A    1
#define C_B    2
#define C_C    3
#define C_D    4
#define C_E    5
#define C_F    6
#define C_G    7
#define C_H    8
#define C_I    9
#define C_J   10
#define C_K   11
#define C_L   12
#define C_M   13
#define C_N   14
#define C_O   15
#define C_P   16
#define C_Q   17
#define C_R   18
#define C_S   19
#define C_T   20
#define C_U   21
#define C_V   22
#define C_W   23
#define C_X   24
#define C_Y   25
#define C_Z   26
#define C_D0  27
#define C_D1  28
#define C_D2  29
#define C_D3  30
#define C_D4  31
#define C_D5  32
#define C_D6  33
#define C_D7  34
#define C_D8  35
#define C_D9  36
#define C_DOT 37
#define C_PCT 38
#define C_DSH 39
#define C_CLN 40
#define C_PLS 41

__DEVICE__ int glyph_row(int c, int r) {
    int r0 = 0, r1 = 0, r2 = 0, r3 = 0, r4 = 0, r5 = 0, r6 = 0;
    if      (c == C_A)   { r0=0x0E; r1=0x11; r2=0x11; r3=0x1F; r4=0x11; r5=0x11; r6=0x11; }
    else if (c == C_B)   { r0=0x1E; r1=0x11; r2=0x11; r3=0x1E; r4=0x11; r5=0x11; r6=0x1E; }
    else if (c == C_C)   { r0=0x0E; r1=0x11; r2=0x10; r3=0x10; r4=0x10; r5=0x11; r6=0x0E; }
    else if (c == C_D)   { r0=0x1C; r1=0x12; r2=0x11; r3=0x11; r4=0x11; r5=0x12; r6=0x1C; }
    else if (c == C_E)   { r0=0x1F; r1=0x10; r2=0x10; r3=0x1E; r4=0x10; r5=0x10; r6=0x1F; }
    else if (c == C_F)   { r0=0x1F; r1=0x10; r2=0x10; r3=0x1E; r4=0x10; r5=0x10; r6=0x10; }
    else if (c == C_G)   { r0=0x0E; r1=0x11; r2=0x10; r3=0x17; r4=0x11; r5=0x11; r6=0x0F; }
    else if (c == C_H)   { r0=0x11; r1=0x11; r2=0x11; r3=0x1F; r4=0x11; r5=0x11; r6=0x11; }
    else if (c == C_I)   { r0=0x0E; r1=0x04; r2=0x04; r3=0x04; r4=0x04; r5=0x04; r6=0x0E; }
    else if (c == C_J)   { r0=0x07; r1=0x02; r2=0x02; r3=0x02; r4=0x02; r5=0x12; r6=0x0C; }
    else if (c == C_K)   { r0=0x11; r1=0x12; r2=0x14; r3=0x18; r4=0x14; r5=0x12; r6=0x11; }
    else if (c == C_L)   { r0=0x10; r1=0x10; r2=0x10; r3=0x10; r4=0x10; r5=0x10; r6=0x1F; }
    else if (c == C_M)   { r0=0x11; r1=0x1B; r2=0x15; r3=0x15; r4=0x11; r5=0x11; r6=0x11; }
    else if (c == C_N)   { r0=0x11; r1=0x19; r2=0x15; r3=0x13; r4=0x11; r5=0x11; r6=0x11; }
    else if (c == C_O)   { r0=0x0E; r1=0x11; r2=0x11; r3=0x11; r4=0x11; r5=0x11; r6=0x0E; }
    else if (c == C_P)   { r0=0x1E; r1=0x11; r2=0x11; r3=0x1E; r4=0x10; r5=0x10; r6=0x10; }
    else if (c == C_Q)   { r0=0x0E; r1=0x11; r2=0x11; r3=0x11; r4=0x15; r5=0x12; r6=0x0D; }
    else if (c == C_R)   { r0=0x1E; r1=0x11; r2=0x11; r3=0x1E; r4=0x14; r5=0x12; r6=0x11; }
    else if (c == C_S)   { r0=0x0F; r1=0x10; r2=0x10; r3=0x0E; r4=0x01; r5=0x11; r6=0x0E; }
    else if (c == C_T)   { r0=0x1F; r1=0x04; r2=0x04; r3=0x04; r4=0x04; r5=0x04; r6=0x04; }
    else if (c == C_U)   { r0=0x11; r1=0x11; r2=0x11; r3=0x11; r4=0x11; r5=0x11; r6=0x0E; }
    else if (c == C_V)   { r0=0x11; r1=0x11; r2=0x11; r3=0x11; r4=0x11; r5=0x0A; r6=0x04; }
    else if (c == C_W)   { r0=0x11; r1=0x11; r2=0x11; r3=0x15; r4=0x15; r5=0x1B; r6=0x11; }
    else if (c == C_X)   { r0=0x11; r1=0x11; r2=0x0A; r3=0x04; r4=0x0A; r5=0x11; r6=0x11; }
    else if (c == C_Y)   { r0=0x11; r1=0x11; r2=0x0A; r3=0x04; r4=0x04; r5=0x04; r6=0x04; }
    else if (c == C_Z)   { r0=0x1F; r1=0x01; r2=0x02; r3=0x04; r4=0x08; r5=0x10; r6=0x1F; }
    else if (c == C_D0)  { r0=0x0E; r1=0x11; r2=0x13; r3=0x15; r4=0x19; r5=0x11; r6=0x0E; }
    else if (c == C_D1)  { r0=0x04; r1=0x0C; r2=0x04; r3=0x04; r4=0x04; r5=0x04; r6=0x0E; }
    else if (c == C_D2)  { r0=0x0E; r1=0x11; r2=0x01; r3=0x02; r4=0x04; r5=0x08; r6=0x1F; }
    else if (c == C_D3)  { r0=0x1F; r1=0x02; r2=0x04; r3=0x02; r4=0x01; r5=0x11; r6=0x0E; }
    else if (c == C_D4)  { r0=0x02; r1=0x06; r2=0x0A; r3=0x12; r4=0x1F; r5=0x02; r6=0x02; }
    else if (c == C_D5)  { r0=0x1F; r1=0x10; r2=0x1E; r3=0x01; r4=0x01; r5=0x11; r6=0x0E; }
    else if (c == C_D6)  { r0=0x06; r1=0x08; r2=0x10; r3=0x1E; r4=0x11; r5=0x11; r6=0x0E; }
    else if (c == C_D7)  { r0=0x1F; r1=0x01; r2=0x02; r3=0x04; r4=0x08; r5=0x08; r6=0x08; }
    else if (c == C_D8)  { r0=0x0E; r1=0x11; r2=0x11; r3=0x0E; r4=0x11; r5=0x11; r6=0x0E; }
    else if (c == C_D9)  { r0=0x0E; r1=0x11; r2=0x11; r3=0x0F; r4=0x01; r5=0x02; r6=0x0C; }
    else if (c == C_DOT) { r0=0x00; r1=0x00; r2=0x00; r3=0x00; r4=0x00; r5=0x0C; r6=0x0C; }
    else if (c == C_PCT) { r0=0x19; r1=0x1A; r2=0x02; r3=0x04; r4=0x08; r5=0x0B; r6=0x13; }
    else if (c == C_DSH) { r0=0x00; r1=0x00; r2=0x00; r3=0x0E; r4=0x00; r5=0x00; r6=0x00; }
    else if (c == C_CLN) { r0=0x00; r1=0x0C; r2=0x0C; r3=0x00; r4=0x0C; r5=0x0C; r6=0x00; }
    else if (c == C_PLS) { r0=0x00; r1=0x04; r2=0x04; r3=0x1F; r4=0x04; r5=0x04; r6=0x00; }
    return (r==0)?r0:((r==1)?r1:((r==2)?r2:((r==3)?r3:((r==4)?r4:((r==5)?r5:r6)))));
}

__DEVICE__ float txt_bit(float px, float py, float x0, float y0, float fp, int n,
                         int c0,int c1,int c2,int c3,int c4,int c5,
                         int c6,int c7,int c8,int c9,int c10)
{
    float lx = (px - x0) / fp;
    float ly = (py - y0) / fp;
    if (lx < 0.0f || ly < 0.0f || ly >= 7.0f) return 0.0f;
    int idx = (int)(lx * 0.1666666667f);
    if (idx >= n) return 0.0f;
    float gx = lx - (float)idx * 6.0f;
    if (gx >= 5.0f) return 0.0f;
    int c = (idx==0)?c0:((idx==1)?c1:((idx==2)?c2:((idx==3)?c3:((idx==4)?c4:
            ((idx==5)?c5:((idx==6)?c6:((idx==7)?c7:((idx==8)?c8:
            ((idx==9)?c9:c10)))))))));
    int rw = glyph_row(c, (int)ly);
    return (float)((rw >> (4 - (int)gx)) & 1);
}

__DEVICE__ float txt_cov(float px, float py, float x0, float y0, float fp, int n,
                         int c0,int c1,int c2,int c3,int c4,int c5,
                         int c6,int c7,int c8,int c9,int c10)
{
    float a = txt_bit(px-0.25f, py-0.25f, x0,y0,fp,n, c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10)
            + txt_bit(px+0.25f, py-0.25f, x0,y0,fp,n, c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10)
            + txt_bit(px-0.25f, py+0.25f, x0,y0,fp,n, c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10)
            + txt_bit(px+0.25f, py+0.25f, x0,y0,fp,n, c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10);
    return a * 0.25f;
}



__DEVICE__ float3 trial_wm(float3 rgb, float px, float py, float Hf) {
    float fp = _fmaxf(Hf / 160.0f, 1.0f);
    float u = px / fp, v = py / fp;
    float row = _floorf(v / 26.0f);
    float sh = (row - 2.0f*_floorf(row*0.5f)) * 42.0f;
    float uu = u + sh;
    float lx = (uu - 84.0f*_floorf(uu / 84.0f)) * fp;
    float ly = (v - 26.0f*row) * fp;
    float c1 = txt_cov(lx, ly, 18.0f*fp, 5.0f*fp, fp, 8,
                       C_N, C_O, C_D, C_E, C_SP, C_D, C_R, C_T, C_SP, C_SP, C_SP);
    float c2 = txt_cov(lx, ly, 9.5f*fp, 14.0f*fp, fp, 11,
                       C_T, C_R, C_I, C_A, C_L, C_SP, C_E, C_N, C_D, C_E, C_D);
    float c = _fmaxf(c1, c2);
    float3 d = rgb * 0.3f;
    return d + (make_float3(0.8f, 0.8f, 0.8f) - d) * c;
}



__DEVICE__ float3 skchk_probe(float3 c) {
    float ap1_r = 0.603141865f*c.x + 0.326348821f*c.y + 0.048032249f*c.z;
    float ap1_g = 0.070048331f*c.x + 0.919956673f*c.y + 0.012762703f*c.z;
    float ap1_b = 0.022148858f*c.x + 0.116083384f*c.y + 0.940986978f*c.z;
    float lms_l = 0.6353221533f*ap1_r + 0.3573570174f*ap1_g + 0.0032861118f*ap1_b;
    float lms_m = 0.2731137454f*ap1_r + 0.6363240167f*ap1_g + 0.0922688645f*ap1_b;
    float lms_s = 0.1013864481f*ap1_r + 0.1881271185f*ap1_g + 0.6580679318f*ap1_b;
    float l_ = _powf(_fmaxf(lms_l,1e-10f),0.333333f);
    float ml_= _powf(_fmaxf(lms_m,1e-10f),0.333333f);
    float s_ = _powf(_fmaxf(lms_s,1e-10f),0.333333f);
    float3 o;
    o.x =  1.9779984951f*l_ - 2.4285922050f*ml_ + 0.4505937099f*s_;   
    o.y =  0.0259040371f*l_ + 0.7827717662f*ml_ - 0.8086757660f*s_;   
    o.z = (l_ + ml_ + s_) * 0.335412f;                                 
    return o;
}

__DEVICE__ float3 draw_check_legend(float3 base, float px, float py, float Wf, float Hf)
{
    float bw = 284.0f;
    float bh = 440.0f;

    float s   = Hf / 1080.0f;
    float smx = (Hf * 0.94f) / bh;
    if (s > smx) s = smx;
    if (s < 0.12f) s = 0.12f;

    float PW = bw * s;
    float PH = bh * s;
    float x0 = 48.0f * s;                   
    float y0 = (Hf - PH) * 0.5f;
    float x1 = x0 + PW;
    float y1 = y0 + PH;

    float mrg = 34.0f * s;
    if (px < x0 - mrg || px > x1 + mrg || py < y0 - mrg || py > y1 + mrg) return base;

    float aa = 0.85f;
    float d  = sd_rbox(px, py, (x0+x1)*0.5f, (y0+y1)*0.5f,
                       PW*0.5f, PH*0.5f, 18.0f*s);

    float3 col = base;

    
    col = over_di(col, make_float3(0.0f, 0.0f, 0.0f),
                  (1.0f - smootherstep(0.0f, 28.0f*s, _fmaxf(d, 0.0f))) * 0.42f);
    col = over_di(col, make_float3(0.075f, 0.085f, 0.125f), cov_sdf(d, aa) * 0.88f);
    col = over_di(col, make_float3(0.560f, 0.480f, 0.320f),
                  cov_sdf(_fabs(d) - _fmaxf(1.15f*s, 0.9f), aa) * 0.80f);

    float ux = px - x0;
    float uy = py - y0;

    float3 c_ttl = make_float3(0.980f, 0.845f, 0.520f);   
    float3 c_txt = make_float3(0.905f, 0.900f, 0.880f);   
    float3 c_rul = make_float3(0.620f, 0.540f, 0.380f);   

    float ft = 4.0f * s;                    
    float fn = 3.0f * s;                    
    float tx = 70.0f * s;                   

    
    col = over_di(col, c_ttl,
          txt_cov(ux, uy, 22.0f * s, 26.0f * s, ft, 10,
                  C_S, C_K, C_I, C_N, C_SP, C_C, C_H, C_E, C_C, C_K, C_SP));

    col = over_di(col, c_rul,
          cov_rect(ux, uy, 20.0f*s, 72.0f*s, PW - 20.0f*s,
                   72.0f*s + _fmaxf(1.6f*s, 1.0f), aa) * 0.55f);

    
    float3 col_yellow  = make_float3(0.520f, 0.494f, 0.000f);
    float3 col_green   = make_float3(0.000f, 0.520f, 0.062f);
    float3 col_magenta = make_float3(0.520f, 0.000f, 0.520f);

    float swx0 = 20.0f * s, swx1 = swx0 + 26.0f * s;   
    float rowGap = 120.0f * s;
    float ry0    = 150.0f * s;

    
    {
        float ry = ry0;
        float dg = sd_rbox(ux, uy, (swx0+swx1)*0.5f, ry, (swx1-swx0)*0.5f, 31.0f*s, 6.0f*s);
        col = over_di(col, col_yellow, cov_sdf(dg, aa));
        col = over_di(col, make_float3(0.520f, 0.470f, 0.400f),
                      cov_sdf(_fabs(dg) - _fmaxf(0.9f*s, 0.8f), aa) * 0.55f);
        col = over_di(col, c_ttl, txt_cov(ux, uy, tx, ry - 10.0f*s, fn, 6,
                      C_Y, C_E, C_L, C_L, C_O, C_W, C_SP,C_SP,C_SP,C_SP,C_SP));
        col = over_di(col, c_txt, txt_cov(ux, uy, tx, ry + 16.0f*s, fn, 9,
                      C_O, C_N, C_SP, C_T, C_A, C_R, C_G, C_E, C_T, C_SP,C_SP));
    }

    
    {
        float ry = ry0 + rowGap;
        float dg = sd_rbox(ux, uy, (swx0+swx1)*0.5f, ry, (swx1-swx0)*0.5f, 31.0f*s, 6.0f*s);
        col = over_di(col, col_green, cov_sdf(dg, aa));
        col = over_di(col, make_float3(0.520f, 0.470f, 0.400f),
                      cov_sdf(_fabs(dg) - _fmaxf(0.9f*s, 0.8f), aa) * 0.55f);
        col = over_di(col, c_ttl, txt_cov(ux, uy, tx, ry - 10.0f*s, fn, 5,
                      C_G, C_R, C_E, C_E, C_N, C_SP,C_SP,C_SP,C_SP,C_SP,C_SP));
        col = over_di(col, c_txt, txt_cov(ux, uy, tx, ry + 16.0f*s, fn, 9,
                      C_T, C_O, C_O, C_SP, C_G, C_R, C_E, C_E, C_N, C_SP,C_SP));
    }

    
    {
        float ry = ry0 + 2.0f * rowGap;
        float dg = sd_rbox(ux, uy, (swx0+swx1)*0.5f, ry, (swx1-swx0)*0.5f, 31.0f*s, 6.0f*s);
        col = over_di(col, col_magenta, cov_sdf(dg, aa));
        col = over_di(col, make_float3(0.520f, 0.470f, 0.400f),
                      cov_sdf(_fabs(dg) - _fmaxf(0.9f*s, 0.8f), aa) * 0.55f);
        col = over_di(col, c_ttl, txt_cov(ux, uy, tx, ry - 10.0f*s, fn, 7,
                      C_M, C_A, C_G, C_E, C_N, C_T, C_A, C_SP,C_SP,C_SP,C_SP));
        col = over_di(col, c_txt, txt_cov(ux, uy, tx, ry + 16.0f*s, fn, 11,
                      C_T, C_O, C_O, C_SP, C_M, C_A, C_G, C_E, C_N, C_T, C_A));
    }

    return col;
}







__DEVICE__ int num_glyph(float v, int k) {
  int c = (int)_round(_fabs(v)*100.0f);
  if (c > 999) c = 999;
  if (k == 0) return (v < 0.0f && c > 0) ? C_DSH : C_PLS;
  if (k == 1) return C_D0 + c/100;
  if (k == 2) return C_DOT;
  if (k == 3) return C_D0 + (c/10)%10;
  return C_D0 + c%10;
}
__DEVICE__ float num_cov(float ux, float uy, float x0, float y0, float fp, float v) {
  return txt_cov(ux, uy, x0, y0, fp, 5, num_glyph(v, 0), num_glyph(v, 1), num_glyph(v, 2),
                 num_glyph(v, 3), num_glyph(v, 4), C_SP, C_SP, C_SP, C_SP, C_SP, C_SP);
}
__DEVICE__ float3 draw_zones_legend(float3 base, float px, float py, float Wf, float Hf,
                                    float b1, float b2, float3 zs, float3 zm, float3 zh, float3 zn)
{
    const float bw = 350.0f, bh = 600.0f;
    float s   = Hf / 1080.0f;
    const float smx = (Hf * 0.94f) / bh;
    if (s > smx) s = smx;
    if (s < 0.12f) s = 0.12f;
    const float PW = bw * s, PH = bh * s;
    const float x0 = 48.0f * s, y0 = (Hf - PH) * 0.5f;
    const float x1 = x0 + PW, y1 = y0 + PH;
    const float mrg = 34.0f * s;
    if (px < x0 - mrg || px > x1 + mrg || py < y0 - mrg || py > y1 + mrg) return base;

    const float aa = 0.85f;
    const float d  = sd_rbox(px, py, (x0+x1)*0.5f, (y0+y1)*0.5f, PW*0.5f, PH*0.5f, 18.0f*s);
    float3 col = base;
    col = over_di(col, make_float3(0.0f, 0.0f, 0.0f),
                  (1.0f - smootherstep(0.0f, 28.0f*s, _fmaxf(d, 0.0f))) * 0.42f);
    col = over_di(col, make_float3(0.075f, 0.085f, 0.125f), cov_sdf(d, aa) * 0.88f);
    col = over_di(col, make_float3(0.560f, 0.480f, 0.320f),
                  cov_sdf(_fabs(d) - _fmaxf(1.15f*s, 0.9f), aa) * 0.80f);

    const float ux = px - x0, uy = py - y0;
    const float3 c_ttl = make_float3(0.980f, 0.845f, 0.520f);
    const float3 c_txt = make_float3(0.905f, 0.900f, 0.880f);
    const float3 c_rul = make_float3(0.620f, 0.540f, 0.380f);
    const float ft = 4.0f * s, fn = 3.0f * s, adv = 6.0f * fn;
    const float tx = 70.0f * s;

    
    col = over_di(col, c_ttl, txt_cov(ux, uy, 55.0f*s, 26.0f*s, ft, 10,
                  C_S, C_K, C_I, C_N, C_SP, C_Z, C_O, C_N, C_E, C_S, C_SP));
    col = over_di(col, c_rul, cov_rect(ux, uy, 20.0f*s, 72.0f*s, PW - 20.0f*s,
                  72.0f*s + _fmaxf(1.6f*s, 1.0f), aa) * 0.55f);

    const float swx0 = 20.0f * s, swx1 = swx0 + 26.0f * s;
    const float gap = 108.0f * s, ry0 = 140.0f * s;
    for (int k = 0; k < 4; ++k) {
        const float ry = ry0 + gap*(float)k;
        const float3 sw = k == 0 ? zh : (k == 1 ? zm : (k == 2 ? zs : zn));
        const float dg = sd_rbox(ux, uy, (swx0+swx1)*0.5f, ry, (swx1-swx0)*0.5f, 31.0f*s, 6.0f*s);
        col = over_di(col, sw, cov_sdf(dg, aa));
        col = over_di(col, make_float3(0.520f, 0.470f, 0.400f),
                      cov_sdf(_fabs(dg) - _fmaxf(0.9f*s, 0.8f), aa) * 0.55f);
        const float ty = ry - 10.0f*s, by = ry + 16.0f*s;
        if (k == 0) {
            col = over_di(col, c_ttl, txt_cov(ux, uy, tx, ty, fn, 10,
                          C_H, C_I, C_G, C_H, C_L, C_I, C_G, C_H, C_T, C_S, C_SP));
            col = over_di(col, c_txt, txt_cov(ux, uy, tx, by, fn, 6,
                          C_A, C_B, C_O, C_V, C_E, C_SP, C_SP, C_SP, C_SP, C_SP, C_SP));
            col = over_di(col, c_txt, num_cov(ux, uy, tx + 6.0f*adv, by, fn, b2));
        } else if (k == 1) {
            col = over_di(col, c_ttl, txt_cov(ux, uy, tx, ty, fn, 8,
                          C_M, C_I, C_D, C_T, C_O, C_N, C_E, C_S, C_SP, C_SP, C_SP));
            col = over_di(col, c_txt, num_cov(ux, uy, tx, by, fn, b1));
            col = over_di(col, c_txt, txt_cov(ux, uy, tx + 5.0f*adv, by, fn, 4,
                          C_SP, C_T, C_O, C_SP, C_SP, C_SP, C_SP, C_SP, C_SP, C_SP, C_SP));
            col = over_di(col, c_txt, num_cov(ux, uy, tx + 9.0f*adv, by, fn, b2));
        } else if (k == 2) {
            col = over_di(col, c_ttl, txt_cov(ux, uy, tx, ty, fn, 7,
                          C_S, C_H, C_A, C_D, C_O, C_W, C_S, C_SP, C_SP, C_SP, C_SP));
            col = over_di(col, c_txt, txt_cov(ux, uy, tx, by, fn, 6,
                          C_B, C_E, C_L, C_O, C_W, C_SP, C_SP, C_SP, C_SP, C_SP, C_SP));
            col = over_di(col, c_txt, num_cov(ux, uy, tx + 6.0f*adv, by, fn, b1));
        } else {
            col = over_di(col, c_ttl, txt_cov(ux, uy, tx, ty, fn, 8,
                          C_N, C_O, C_T, C_SP, C_S, C_K, C_I, C_N, C_SP, C_SP, C_SP));
            col = over_di(col, c_txt, txt_cov(ux, uy, tx, by, fn, 9,
                          C_U, C_N, C_T, C_O, C_U, C_C, C_H, C_E, C_D, C_SP, C_SP));
        }
    }
    
    col = over_di(col, c_rul, cov_rect(ux, uy, 20.0f*s, 540.0f*s, PW - 20.0f*s,
                  540.0f*s + _fmaxf(1.6f*s, 1.0f), aa) * 0.55f);
    col = over_di(col, c_txt, txt_cov(ux, uy, 20.0f*s, 558.0f*s, fn, 11,
                  C_S, C_T, C_O, C_P, C_S, C_SP, C_F, C_R, C_O, C_M, C_SP));
    col = over_di(col, c_txt, txt_cov(ux, uy, 20.0f*s + 11.0f*adv, 558.0f*s, fn, 8,
                  C_D1, C_D8, C_PCT, C_SP, C_G, C_R, C_E, C_Y, C_SP, C_SP, C_SP));
    return col;
}








__DEVICE__ int ovl_glyph_bits(int id) {
    if (id == 0) return 31599;
    if (id == 1) return 29850;
    if (id == 2) return 29671;
    if (id == 3) return 31207;
    if (id == 4) return 18925;
    if (id == 5) return 31183;
    if (id == 6) return 31695;
    if (id == 7) return 9383;
    if (id == 8) return 31727;
    if (id == 9) return 31215;
    if (id == 10) return 1488;
    if (id == 11) return 448;
    if (id == 12) return 8192;
    if (id == 13) return 23277;
    if (id == 15) return 21157;   
    
    
    
    if (id == 16) return 9367;    
    if (id == 17) return 29391;   
    if (id == 18) return 23549;   
    if (id == 19) return 4843;    
    if (id == 20) return 29847;   
    if (id == 21) return 23403;   
    return 0;
}

__DEVICE__ float ovl_glyph_cov(float px, float py, float gx0, float gy0, float sf, int id) {
    int bits = ovl_glyph_bits(id);
    if (bits == 0) return 0.0f;
    float fx = (px - gx0) / sf;
    float fy = (py - gy0) / sf;
    if (fx < 0.0f || fx >= 3.0f || fy < 0.0f || fy >= 5.0f) return 0.0f;
    int cx = (int)fx;
    int cy = (int)fy;
    return (float)((bits >> (cy * 3 + cx)) & 1);
}




__DEVICE__ float ovl_rrect_sdf(float px, float py, float cx, float cy, float hx, float hy, float r) {
    float qx = _fabs(px - cx) - (hx - r);
    float qy = _fabs(py - cy) - (hy - r);
    float ax = _fmaxf(qx, 0.0f);
    float ay = _fmaxf(qy, 0.0f);
    return _sqrtf(ax * ax + ay * ay) + _fminf(_fmaxf(qx, qy), 0.0f) - r;
}


__DEVICE__ float ovl_cov(float d) { return _clampf(0.5f - d, 0.0f, 1.0f); }





__DEVICE__ float ovl_mix(float x, float t, float a) {
    return (a >= 1.0f) ? t : (x + (t - x) * a);
}

__DEVICE__ float ovl_ss(float e0, float e1, float x) {
    float t = _clampf((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}












__DEVICE__ float3 fc_color(float s) {
    int n = 0;
    for (int i = 0; i < 12; ++i) if (s >= -5.5f + (float)i) ++n;   
    float3 c;
    if      (n == 12) c = make_float3(1.00f, 1.00f, 1.00f);   
    else if (n == 11) c = make_float3(1.00f, 0.65f, 0.85f);   
    else if (n == 10) c = make_float3(0.95f, 0.35f, 0.20f);   
    else if (n ==  9) c = make_float3(1.00f, 0.60f, 0.10f);   
    else if (n ==  8) c = make_float3(1.00f, 0.90f, 0.20f);   
    else if (n ==  7) c = make_float3(0.60f, 0.90f, 0.30f);   
    else if (n ==  6) c = make_float3(0.50f, 0.50f, 0.50f);   
    else if (n ==  5) c = make_float3(0.15f, 0.55f, 0.30f);   
    else if (n ==  4) c = make_float3(0.10f, 0.75f, 0.90f);   
    else if (n ==  3) c = make_float3(0.10f, 0.45f, 1.00f);   
    else if (n ==  2) c = make_float3(0.15f, 0.15f, 0.75f);   
    else if (n ==  1) c = make_float3(0.50f, 0.20f, 0.80f);   
    else              c = make_float3(0.30f, 0.00f, 0.40f);   
    return make_float3(spowf(c.x, 2.4f), spowf(c.y, 2.4f), spowf(c.z, 2.4f));
}









#define ok_p3_to_lms make_float3x3(make_float3(0.4813799217f, 0.4621183052f, 0.0565017731f), make_float3(0.2288319819f, 0.6532167902f, 0.1179512279f), make_float3(0.0839457719f, 0.2241652676f, 0.6918889605f))
#define ok_lms_to_p3 make_float3x3(make_float3(3.1277684194f, -2.2571351293f, 0.1293667099f), make_float3(-1.0910090639f, 2.4133317298f, -0.3223226660f), make_float3(-0.0260108145f, -0.5080413513f, 1.5340521659f))
#define ok_rec709_to_lms make_float3x3(make_float3(0.4122215303f, 0.5363324835f, 0.0514459862f), make_float3(0.2119035465f, 0.6806995152f, 0.1073969383f), make_float3(0.0883024866f, 0.2817188412f, 0.6299786721f))
#define ok_lms_to_rec709 make_float3x3(make_float3(4.0767411527f, -3.3077109761f, 0.2309698234f), make_float3(-1.2684381910f, 2.6097575508f, -0.3413193598f), make_float3(-0.0041960844f, -0.7034186848f, 1.7076147691f))

__DEVICE__ float3 ok_rgb_to_lab(float3 c, dctl_float3x3 to_lms) {
  float3 l = vdot(to_lms, c);
  l = make_float3(_cbrtf(l.x), _cbrtf(l.y), _cbrtf(l.z));
  return make_float3(0.2104542553f*l.x + 0.7936177850f*l.y - 0.0040720468f*l.z,
                     1.9779984951f*l.x - 2.4285922050f*l.y + 0.4505937099f*l.z,
                     0.0259040371f*l.x + 0.7827717662f*l.y - 0.8086757660f*l.z);
}
__DEVICE__ float3 ok_lab_to_rgb(float3 lab, dctl_float3x3 from_lms) {
  float l = lab.x + 0.3963377774f*lab.y + 0.2158037573f*lab.z;
  float m = lab.x - 0.1055613458f*lab.y - 0.0638541728f*lab.z;
  float s = lab.x - 0.0894841775f*lab.y - 1.2914855480f*lab.z;
  return vdot(from_lms, make_float3(l*l*l, m*m*m, s*s*s));
}




















#define SKL_A 1.0f
#define SKL_B1 -0.75f
#define SKL_B2 1.25f
#define SKL_T 1.5f
#define SKL_K 4.2f
__DEVICE__ float2 skin_dev(float3 c709) {
  const float A0 = -0.012061f, B0 = 0.014794f;
  const float rac = 0.73728f, rbc = 0.67559f;     
  const float3 pq = skchk_probe(c709);
  const float Ln = _fmaxf(pq.z, 1.0e-4f);
  const float an = pq.x/Ln - A0, bn = pq.y/Ln - B0;
  const float uc = an*rac + bn*rbc, vc = bn*rac - an*rbc;
  const float nc = _sqrtf(uc*uc + vc*vc);
  const float phi = _atan2f(vc, uc);
  
  
  
  
  
  
  
  
  
  const float3 klab = ovl_oklab(c709);
  const float kC = _sqrtf(klab.y*klab.y + klab.z*klab.z);
  const float cr = kC/_fmaxf(klab.x, 1.0e-4f);
  float w = smootherstep(0.015f, 0.05f, cr)*(1.0f - smootherstep(0.24f, 0.34f, cr));
  w *= smootherstep(0.004f, 0.020f, fmaxf3(c709));
  
  
  
  
  
  
  
  
  
  w *= phi >= 0.0f ? 1.0f - smootherstep(0.2094f, 0.5236f, phi)
                   : 1.0f - smootherstep(0.2618f, 0.7854f, -phi);
  return make_float2(phi, w);
}






































__DEVICE__ float atan2_mask(float y, float x) {
  const float ax = _fabs(x), ay = _fabs(y);
  const float mx = _fmaxf(ax, ay), mn = _fminf(ax, ay);
  if (mx <= 0.0f) return 0.0f;
  const float a = mn/mx, s = a*a;
  float r = a*(0.99997726f + s*(-0.33262347f + s*(0.19354346f + s*(-0.11643287f + s*(0.05265332f + s*(-0.01172120f))))));
  if (ay > ax) r = 1.57079633f - r;
  if (x < 0.0f) r = 3.14159265f - r;
  return y < 0.0f ? -r : r;
}

__DEVICE__ float2 skin_feat(float3 c709) {
  const float A0 = -0.012061f, B0 = 0.014794f;
  const float rac = 0.73728f, rbc = 0.67559f;
  const float3 pq = skchk_probe(c709);
  const float Ln = _fmaxf(pq.z, 1.0e-4f);
  const float an = pq.x/Ln - A0, bn = pq.y/Ln - B0;
  const float uc = an*rac + bn*rbc, vc = bn*rac - an*rbc;
  return make_float2(atan2_mask(vc, uc), _sqrtf(an*an + bn*bn)*1.0243f);
}

__DEVICE__ float skin_win_s(float2 f) {
  const float phi = f.x, cr = f.y;
  float w = smootherstep(0.015f, 0.05f, cr)*(1.0f - smootherstep(0.24f, 0.34f, cr));
  w *= phi >= 0.0f ? 1.0f - smootherstep(0.0873f, 0.5236f, phi)
                   : 1.0f - smootherstep(0.6109f, 1.1345f, -phi);
  return w;
}










__DEVICE__ float skin_win_l(float2 fe, float soft) {
  const float phi = fe.x, cr = fe.y;
  const float f = _exp2f(_fminf(soft - 0.5f, 0.0f)*3.0f);
  const float h = _clampf((soft - 0.5f)*2.0f, 0.0f, 1.0f);
  const float c0 = _fmaxf(0.0325f - 0.0175f*f - 0.013f*h, 0.002f), c1 = 0.0325f + 0.0175f*f;
  const float c2 = 0.29f - 0.05f*f, c3 = 0.29f + 0.05f*f + 0.40f*h;
  const float y0 = _fmaxf(0.3054f - 0.2182f*f, 0.03f), y1 = 0.3054f + 0.2182f*f + 0.80f*h;
  const float m0 = _fmaxf(1.2654f - 0.3927f*f, 0.08f), m1 = 1.2654f + 0.3927f*f + 1.60f*h;
  float w = smootherstep(c0, c1, cr)*(1.0f - smootherstep(c2, c3, cr));
  w *= phi >= 0.0f ? 1.0f - smootherstep(y0, y1, phi)
                   : 1.0f - smootherstep(m0, m1, -phi);
  return w;
}

__DEVICE__ float3 skin_line(float3 rgb, int p3, float k, float wsp) {
  const dctl_float3x3 to_lms = p3 ? ok_p3_to_lms : ok_rec709_to_lms;
  const dctl_float3x3 from_lms = p3 ? ok_lms_to_p3 : ok_lms_to_rec709;
  const float3 c709 = p3 ? vdot(matrix_p3_to_rec709_d65, rgb) : rgb;
  const float2 d0 = skin_dev(c709);
  
  
  
  
  
  const float3 sl_lab = ovl_oklab(c709);
  const float sl_cr = _sqrtf(sl_lab.y*sl_lab.y + sl_lab.z*sl_lab.z)/_fmaxf(sl_lab.x, 1.0e-4f);
  const float sl_g = smootherstep(0.015f, 0.05f, sl_cr)*(1.0f - smootherstep(0.24f, 0.34f, sl_cr))
                   * smootherstep(0.004f, 0.020f, fmaxf3(c709));
  const float kw = k*wsp*sl_g;
  if (kw <= 0.0f) return rgb;
  
  const float3 yw = p3 ? make_float3(0.228974640369f, 0.691738605499f, 0.079286918044f)
                       : make_float3(0.212639078498f, 0.715168714523f, 0.072192311287f);
  const float Y0 = yw.x*rgb.x + yw.y*rgb.y + yw.z*rgb.z;
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  const float sl_s = d0.x < 0.0f ? 0.3840f : 0.2618f;
  const float sl_b = _expf(-0.5f*(d0.x/sl_s)*(d0.x/sl_s));
  const float target = d0.x - kw*d0.x*sl_b;
  float3 c = rgb;
  for (int it = 0; it < 3; ++it) {
    const float cur = it == 0 ? d0.x : skin_dev(p3 ? vdot(matrix_p3_to_rec709_d65, c) : c).x;
    const float dh = target - cur;
    const float3 lab = ok_rgb_to_lab(c, to_lms);
    const float cs = _cosf(dh), sn = _sinf(dh);
    c = ok_lab_to_rgb(make_float3(lab.x, lab.y*cs - lab.z*sn, lab.y*sn + lab.z*cs), from_lms);
  }
  
  const float Y1 = yw.x*c.x + yw.y*c.y + yw.z*c.z;
  if (Y1 > 1.0e-9f) c = c*(Y0/Y1);
  return c;
}











typedef struct { float3 r; float tsn; float pt; float sh; float3 crv; float y0; } ts_out;
__DEVICE__ ts_out ts_core(float3 rgb, float3 crv_val, int crv_on,
                          float pt_r, float pt_g, float pt_b,
                          float Lg, float con, float shc, float toe, float off,
                          float hcon, float hcon_pv, float hcon_st,
                          float lcon, float lcon_w, float lcon_pc,
                          float Lp, float gb, float pt_hdr) {
  const float ts_x1 = _powf(2.0f, 6.0f*shc + 4.0f);
  const float ts_y1 = Lp/100.0f;
  const float ts_x0 = 0.18f + off;
  const float ts_y0 = Lg/100.0f*(1.0f + gb*_log2f(ts_y1));
  const float ts_s0 = compress_toe_quadratic(ts_y0, toe, 1);
  const float ts_s10 = ts_x0*(_powf(ts_s0, -1.0f/con) - 1.0f);
  const float ts_m1 = ts_y1/_powf(ts_x1/(ts_x1 + ts_s10), con);
  const float ts_m2 = compress_toe_quadratic(ts_m1, toe, 1);
  const float ts_s = ts_x0*(_powf(ts_s0/ts_m2, -1.0f/con) - 1.0f);
  const float pt_cmp_Lf = pt_hdr*_fminf(1.0f, (Lp - 100.0f)/900.0f);
  const float s_Lp100 = ts_x0*(_powf((Lg/100.0f), -1.0f/con) - 1.0f);
  const float ts_s1 = ts_s*pt_cmp_Lf + s_Lp100*(1.0f - pt_cmp_Lf);

  rgb += off;
  float sh_fl = off;
  if (crv_on) crv_val += off;
  {
    float mcon_m = _powf(2.0f, -lcon);
    float mcon_w = lcon_w/4.0f;
    mcon_w *= mcon_w;
    const float mcon_cnst_sc = compress_toe_cubic(ts_x0, mcon_m, mcon_w, 1)/ts_x0;
    rgb *= mcon_cnst_sc;
    sh_fl *= mcon_cnst_sc;
    sh_fl = sh_fl*(sh_fl*sh_fl + mcon_m*mcon_w)/(sh_fl*sh_fl + mcon_w);
    float mcon_nm = hypotf3(clampminf3(rgb, 0.0f))/SQRT3;
    float mcon_sc = (mcon_nm*mcon_nm + mcon_m*mcon_w)/(mcon_nm*mcon_nm + mcon_w);
    if (lcon_pc > 0.0f) {
      float3 mcon_rgb = rgb;
      mcon_rgb.x = compress_toe_cubic(rgb.x, mcon_m, mcon_w, 0);
      mcon_rgb.y = compress_toe_cubic(rgb.y, mcon_m, mcon_w, 0);
      mcon_rgb.z = compress_toe_cubic(rgb.z, mcon_m, mcon_w, 0);
      float mcon_mx = fmaxf3(rgb);
      float mcon_mn = fminf3(rgb);
      float mcon_ch = clampf(1.0f - sdivf(mcon_mn, mcon_mx), 0.0, 1.0);
      mcon_ch = _powf(mcon_ch, 4.0f*lcon_pc);
      rgb = mcon_sc*rgb*mcon_ch + mcon_rgb*(1.0f - mcon_ch);
    }
    else rgb = mcon_sc*rgb;
    if (crv_on) {
      crv_val *= mcon_cnst_sc;
      crv_val = crv_val*(crv_val*crv_val + mcon_m*mcon_w)/(crv_val*crv_val + mcon_w);
    }
  }
  float tsn = hypotf3(clampminf3(rgb, 0.0f))/SQRT3;
  if (crv_on) crv_val = clampminf3(crv_val, 0.0f);
  float ts_pt = _sqrtf(_fmaxf(0.0f, rgb.x*rgb.x*pt_r + rgb.y*rgb.y*pt_g + rgb.z*rgb.z*pt_b));
  rgb = sdivf3f(clampminf3(rgb, -2.0f), tsn);
  {
    float hcon_p = _powf(2.0f, hcon);
    tsn = contrast_high(tsn, hcon_p, hcon_pv, hcon_st, 0);
    ts_pt = contrast_high(ts_pt, hcon_p, hcon_pv, hcon_st, 0);
    sh_fl = contrast_high(sh_fl, hcon_p, hcon_pv, hcon_st, 0);
    if (crv_on) crv_val = make_float3(contrast_high(crv_val.x, hcon_p, hcon_pv, hcon_st, 0),
                                      contrast_high(crv_val.y, hcon_p, hcon_pv, hcon_st, 0),
                                      contrast_high(crv_val.z, hcon_p, hcon_pv, hcon_st, 0));
  }
  tsn = compress_hyperbolic_power(tsn, ts_s, con);
  ts_pt = compress_hyperbolic_power(ts_pt, ts_s1, con);
  sh_fl = compress_hyperbolic_power(sh_fl, ts_s, con);
  if (crv_on) crv_val = make_float3(compress_hyperbolic_power(crv_val.x, ts_s, con),
                                    compress_hyperbolic_power(crv_val.y, ts_s, con),
                                    compress_hyperbolic_power(crv_val.z, ts_s, con));
  ts_out o;
  o.r = rgb;
  o.tsn = compress_toe_quadratic(tsn*ts_m2, toe, 0);
  o.pt = ts_pt;
  o.sh = compress_toe_quadratic(sh_fl*ts_m2, toe, 0);
  o.crv = crv_on ? make_float3(compress_toe_quadratic(crv_val.x*ts_m2, toe, 0),
                               compress_toe_quadratic(crv_val.y*ts_m2, toe, 0),
                               compress_toe_quadratic(crv_val.z*ts_m2, toe, 0)) : crv_val;
  o.y0 = ts_y0;
  return o;
}


__DEVICE__ float ts_mix(float a, float b, float k) {
  const float ea = spowf(_fmaxf(a, 0.0f), 1.0f/2.4f), eb = spowf(_fmaxf(b, 0.0f), 1.0f/2.4f);
  return spowf(ea + (eb - ea)*k, 2.4f);
}




































#define SKM_TAPS 17
#define SKM_R1 0.5f
__DEVICE__ float3 skin_proxy_p3(float3 code, int tf, dctl_float3x3 pre, float rs_sa, float3 rs_w) {
  float3 c = vdot(pre, linearize(code, tf));
  const float L = c.x*rs_w.x + c.y*rs_w.y + c.z*rs_w.z;
  return L*rs_sa + c*(1.0f - rs_sa);
}




__DEVICE__ float2 skin_mask_spatial(__TEXTURE__ tR, __TEXTURE__ tG, __TEXTURE__ tB,
                                    int X, int Y, int H, int tf, dctl_float3x3 pre,
                                    float rs_sa, float3 rs_w, float gain, float soft,
                                    int need_s, int need_l) {
  const float R = _fmaxf(1.0f, (float)H/360.0f);
  const float3 yw = make_float3(0.2289746f, 0.6917385f, 0.0792869f);
  float ws = 0.0f, wl = 0.0f, gs = 0.0f, lyc = 0.0f;
  for (int k = 0; k < SKM_TAPS; ++k) {
    
    
    
    float ox = 0.0f, oy = 0.0f, gsp = 1.0f;
    if (k >= 1 && k <= 8) {
      const int j = k - 1;
      const float cx = j == 0 ? 1.0f : j == 1 ? 0.70710678f : j == 2 ? 0.0f : j == 3 ? -0.70710678f
                     : j == 4 ? -1.0f : j == 5 ? -0.70710678f : j == 6 ? 0.0f : 0.70710678f;
      const float cy = j == 0 ? 0.0f : j == 1 ? 0.70710678f : j == 2 ? 1.0f : j == 3 ? 0.70710678f
                     : j == 4 ? 0.0f : j == 5 ? -0.70710678f : j == 6 ? -1.0f : -0.70710678f;
      ox = SKM_R1*R*cx; oy = SKM_R1*R*cy; gsp = 0.75f;
    } else if (k >= 9) {
      const int j = k - 9;
      const float cx = j == 0 ? 0.92387953f : j == 1 ? 0.38268343f : j == 2 ? -0.38268343f : j == 3 ? -0.92387953f
                     : j == 4 ? -0.92387953f : j == 5 ? -0.38268343f : j == 6 ? 0.38268343f : 0.92387953f;
      const float cy = j == 0 ? 0.38268343f : j == 1 ? 0.92387953f : j == 2 ? 0.92387953f : j == 3 ? 0.38268343f
                     : j == 4 ? -0.38268343f : j == 5 ? -0.92387953f : j == 6 ? -0.92387953f : -0.38268343f;
      ox = R*cx; oy = R*cy; gsp = 0.40f;
    }
    const int xx = X + (int)_floorf(ox + 0.5f);
    const int yy = Y + (int)_floorf(oy + 0.5f);
    const float3 code = make_float3(_tex2D(tR, xx, yy), _tex2D(tG, xx, yy), _tex2D(tB, xx, yy));
    const float3 p3 = skin_proxy_p3(code, tf, pre, rs_sa, rs_w)*gain;
    const float ly = _log2f(_fmaxf(yw.x*p3.x + yw.y*p3.y + yw.z*p3.z, 1.0e-8f));
    if (k == 0) lyc = ly;
    const float dl = ly - lyc;
    const float g = gsp*_expf(-0.5f*dl*dl/(0.75f*0.75f));
    const float3 c709 = vdot(matrix_p3_to_rec709_d65, p3);
    const float m = fmaxf3(c709);
    if (m > 1.0e-6f) {
      const float gate = smootherstep(-12.0f, -7.5f, _log2f(m));
      const float3 cn = c709*(0.5f/m);
      const float2 fe = skin_feat(cn);
      if (need_s) ws += g*skin_win_s(fe)*gate;
      if (need_l) wl += g*skin_win_l(fe, soft)*gate;
    }
    gs += g;
  }
  return make_float2(ws/gs, wl/gs);
}

__DEVICE__ float3 dctl_transform(__PARAMSREF__ DctlParams& P_, int p_Width, int p_Height, int p_X, int p_Y, __TEXTURE__ p_TexR, __TEXTURE__ p_TexG, __TEXTURE__ p_TexB) {int in_gamut = P_.in_gamut; int in_oetf = P_.in_oetf; float tn_Lp = P_.tn_Lp; float tn_gb = P_.tn_gb; float pt_hdr = P_.pt_hdr; int out_clamp = P_.out_clamp; int crv_enable = P_.crv_enable; float crv_size = P_.crv_size; int fc_overlay = P_.fc_overlay; int skin_check = P_.skin_check; int legend = P_.legend; int look_preset = P_.look_preset; int look_bypass = P_.look_bypass; int print_tone_sel = P_.print_tone_sel; int tone_bypass = P_.tone_bypass; int wb_preset = P_.wb_preset; float wb_kelvin = P_.wb_kelvin; float wb_temp = P_.wb_temp; float wb_tint = P_.wb_tint; int wb_bypass = P_.wb_bypass; int cw_bypass = P_.cw_bypass; int _cwp = P_._cwp; float _cwp_rng = P_._cwp_rng; float col_weight = P_.col_weight; float col_dens = P_.col_dens; int col_bypass = P_.col_bypass; float col_chroma = P_.col_chroma; float col_ptw = P_.col_ptw; float col_onset = P_.col_onset; int trim_con_bypass = P_.trim_con_bypass; int trim_hl_bypass = P_.trim_hl_bypass; int trim_mid_bypass = P_.trim_mid_bypass; float trim_con = P_.trim_con; float trim_piv = P_.trim_piv; float trim_ovl = P_.trim_ovl; float trim_sh = P_.trim_sh; float trim_hp = P_.trim_hp; float trim_hd = P_.trim_hd; float trim_br = P_.trim_br; float trim_hs = P_.trim_hs; float trim_mp = P_.trim_mp; float trim_mp_pv = P_.trim_mp_pv; float trim_skin = P_.trim_skin; float trim_skin_sat = P_.trim_skin_sat; float skin_piv = P_.skin_piv; float skin_soft = P_.skin_soft; int skin_zones = P_.skin_zones; int skin_col_bypass = P_.skin_col_bypass; int skin_light_bypass = P_.skin_light_bypass; float skin_hi = P_.skin_hi; float skin_mid = P_.skin_mid; float skin_sh = P_.skin_sh; int tone_curve_bypass = P_.tone_curve_bypass; int tonescale_preset = P_.tonescale_preset; float ts_intensity = P_.ts_intensity; int credits = P_.credits; int trial_mark = P_.trial_mark; int display_encoding_preset = P_.display_encoding_preset; float look_intensity = P_.look_intensity; float tone_intensity = P_.tone_intensity; (void)0;
  
  
  
  
  
  float3 rgb = make_float3(_tex2D(p_TexR, p_X, p_Y),
                           _tex2D(p_TexG, p_X, p_Y),
                           _tex2D(p_TexB, p_X, p_Y));

  












  const float3 lk_in = rgb;
  const float lk_t = look_bypass ? 0.0f : _clampf(look_intensity, 0.0f, 1.0f);
  const int lk_passes = (lk_t > 0.0f && lk_t < 1.0f) ? 2 : 1;
  float3 lk_full = make_float3(0.0f, 0.0f, 0.0f), lk_full_crv = make_float3(0.0f, 0.0f, 0.0f);
  for (int lk_pass = 0; lk_pass < lk_passes; ++lk_pass) {
  rgb = lk_in;

  



  
  int tn_hcon_enable, tn_lcon_enable, ptl_enable, ptm_enable, brl_enable, hs_rgb_enable, hs_cmy_enable, hc_enable, cwp;
  int display_gamut = 0, eotf = 2; 
  int tone_id = 0;
  float look_exp = 1.0f;
  float tn_Lg, tn_con, tn_sh, tn_toe, tn_off, tn_hcon, tn_hcon_pv, tn_hcon_st, tn_lcon, tn_lcon_w, tn_lcon_pc, cwp_rng, rs_sa, rs_rw, rs_bw, pt_r, pt_g, pt_b, pt_rng_low, pt_rng_high, ptm_low, ptm_low_st, ptm_high, ptm_high_st, brl_r, brl_g, brl_b, brl_c, brl_m, brl_y, brl_rng, hs_r, hs_g, hs_b, hs_rgb_rng, hs_c, hs_m, hs_y, hc_r;

  #ifdef INIT_PARAMS  

  tn_Lg=_tn_Lg, tn_con=_tn_con, tn_sh=_tn_sh, tn_toe=_tn_toe, tn_off=_tn_off, tn_hcon_enable=_tn_hcon_enable, tn_hcon=_tn_hcon, tn_hcon_pv=_tn_hcon_pv, tn_hcon_st=_tn_hcon_st, tn_lcon_enable=_tn_lcon_enable, tn_lcon=_tn_lcon, tn_lcon_w=_tn_lcon_w, tn_lcon_pc=_tn_lcon_pc, cwp=_cwp, cwp_rng=_cwp_rng, rs_sa=_rs_sa, rs_rw=_rs_rw, rs_bw=_rs_bw, pt_r=_pt_r, pt_g=_pt_g, pt_b=_pt_b, pt_rng_low=_pt_rng_low, pt_rng_high=_pt_rng_high, ptl_enable=_ptl_enable, ptm_enable=_ptm_enable, ptm_low=_ptm_low, ptm_low_st=_ptm_low_st, ptm_high=_ptm_high, ptm_high_st=_ptm_high_st, brl_enable=_brl_enable, brl_r=_brl_r, brl_g=_brl_g, brl_b=_brl_b, brl_c=_brl_c, brl_m=_brl_m, brl_y=_brl_y, brl_rng=_brl_rng, hs_rgb_enable=_hs_rgb_enable, hs_r=_hs_r, hs_g=_hs_g, hs_b=_hs_b, hs_rgb_rng=_hs_rgb_rng, hs_cmy_enable=_hs_cmy_enable, hs_c=_hs_c, hs_m=_hs_m, hs_y=_hs_y, hc_enable=_hc_enable, hc_r=_hc_r, display_gamut=_display_gamut, eotf=_eotf;

  #else 

  
  
  
  
  
  
  int lk_sel = look_preset;
  
  
  
  const int ts_sel = tone_curve_bypass ? 0 : tonescale_preset;
  if (lk_sel == 2)      lk_sel = 3;
  else if (lk_sel == 3) lk_sel = 2;

  
  if (lk_sel<1 || lk_sel>7) { 
    tn_Lg = 11.1f, tn_con = 1.4f, tn_sh = 0.5f, tn_toe = 0.003f, tn_off = 0.005f, tn_hcon_enable = 0, tn_hcon = 0.0f, tn_hcon_pv = 1.0f, tn_hcon_st = 4.0f, tn_lcon_enable = 1, tn_lcon = 1.0f, tn_lcon_w = 0.5f, tn_lcon_pc = 1.0f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.35f, rs_rw = 0.25f, rs_bw = 0.55f, pt_r = 0.5f, pt_g = 2.0f, pt_b = 2.0f, pt_rng_low = 0.2f, pt_rng_high = 0.8f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.2f, ptm_low_st = 0.5f, ptm_high = -0.8f, ptm_high_st = 0.3f, brl_enable = 1, brl_r = -0.5f, brl_g = -0.4f, brl_b = -0.2f, brl_c = 0.0f, brl_m = 0.0f, brl_y = 0.0f, brl_rng = 0.66f, hs_rgb_enable = 1, hs_r = 0.35f, hs_g = 0.25f, hs_b = 0.5f, hs_rgb_rng = 0.6f, hs_cmy_enable = 1, hs_c = 0.2f, hs_m = 0.2f, hs_y = 0.2f, hc_enable = 1, hc_r = 0.6f;
  }
  else if (lk_sel==1) { 
    tn_Lg = 8.4827f, tn_con = 1.2968f, tn_sh = 0.0001f, tn_toe = 0.004f, tn_off = 0.0051f, tn_hcon_enable = 1, tn_hcon = -0.6264f, tn_hcon_pv = 3.9994f, tn_hcon_st = 3.9366f, tn_lcon_enable = 1, tn_lcon = 1.9209f, tn_lcon_w = 1.8948f, tn_lcon_pc = 1.0f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.2486f, rs_rw = 0.0037f, rs_bw = 0.414f, pt_r = 0.4319f, pt_g = 0.5366f, pt_b = 1.5762f, pt_rng_low = 0.1694f, pt_rng_high = 0.2501f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.0855f, ptm_low_st = 0.6777f, ptm_high = -0.154f, ptm_high_st = 0.2319f, brl_enable = 1, brl_r = -0.6989f, brl_g = -0.7993f, brl_b = -0.6458f, brl_c = -0.1948f, brl_m = -0.5f, brl_y = 0.0928f, brl_rng = 0.9507f, hs_rgb_enable = 1, hs_r = 0.0012f, hs_g = 1.0f, hs_b = 0.6603f, hs_rgb_rng = 0.4191f, hs_cmy_enable = 1, hs_c = 1.0f, hs_m = 0.0935f, hs_y = 0.99f, hc_enable = 1, hc_r = 1.0f, tone_id = 1, look_exp = 1.19317f;
  }
  else if (lk_sel==2) { 
    tn_Lg = 5.5795f, tn_con = 1.4533f, tn_sh = 0.0001f, tn_toe = 0.0026f, tn_off = 0.0104f, tn_hcon_enable = 1, tn_hcon = -0.4426f, tn_hcon_pv = 4.0f, tn_hcon_st = 3.9998f, tn_lcon_enable = 1, tn_lcon = 2.0959f, tn_lcon_w = 1.9998f, tn_lcon_pc = 0.9843f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.3234f, rs_rw = 0.0025f, rs_bw = 0.3174f, pt_r = 0.3304f, pt_g = 0.0981f, pt_b = 2.0144f, pt_rng_low = 0.1672f, pt_rng_high = 0.25f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.2765f, ptm_low_st = 0.5582f, ptm_high = -0.195f, ptm_high_st = 0.2268f, brl_enable = 1, brl_r = -0.7532f, brl_g = -0.9362f, brl_b = -0.6598f, brl_c = -0.1415f, brl_m = -0.5f, brl_y = 0.1549f, brl_rng = 1.0f, hs_rgb_enable = 1, hs_r = 0.0004f, hs_g = 1.0f, hs_b = 0.5629f, hs_rgb_rng = 1.0f, hs_cmy_enable = 1, hs_c = 1.0f, hs_m = 0.0143f, hs_y = 0.9984f, hc_enable = 1, hc_r = 1.0f, tone_id = 2, look_exp = 1.47471f;
  }
  else if (lk_sel==3) { 
    tn_Lg = 12.7219f, tn_con = 1.2137f, tn_sh = 0.0005f, tn_toe = 0.0222f, tn_off = 0.02f, tn_hcon_enable = 1, tn_hcon = -0.5094f, tn_hcon_pv = 3.7592f, tn_hcon_st = 3.8482f, tn_lcon_enable = 1, tn_lcon = 2.2614f, tn_lcon_w = 1.5425f, tn_lcon_pc = 1.0f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.2681f, rs_rw = 0.0001f, rs_bw = 0.8f, pt_r = 0.2429f, pt_g = 3.7646f, pt_b = 0.0005f, pt_rng_low = 0.1724f, pt_rng_high = 0.3997f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.5889f, ptm_low_st = 0.1995f, ptm_high = -0.0001f, ptm_high_st = 0.2889f, brl_enable = 1, brl_r = -0.7098f, brl_g = -0.6936f, brl_b = -0.8106f, brl_c = -0.0644f, brl_m = -0.5f, brl_y = -0.0827f, brl_rng = 1.0f, hs_rgb_enable = 1, hs_r = 0.0622f, hs_g = 1.0f, hs_b = 0.4495f, hs_rgb_rng = 0.9893f, hs_cmy_enable = 1, hs_c = 1.0f, hs_m = 0.2457f, hs_y = 1.0f, hc_enable = 1, hc_r = 1.0f, tone_id = 3, look_exp = 0.94893f;
  }
  else if (lk_sel==4) { 
    tn_Lg = 24.9919f, tn_con = 1.3699f, tn_sh = 0.0001f, tn_toe = 0.0164f, tn_off = 0.0495f, tn_hcon_enable = 1, tn_hcon = 0.9994f, tn_hcon_pv = 1.1745f, tn_hcon_st = 0.7505f, tn_lcon_enable = 1, tn_lcon = 2.9999f, tn_lcon_w = 2.0f, tn_lcon_pc = 1.0f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.1453f, rs_rw = 0.0013f, rs_bw = 0.3907f, pt_r = 0.0533f, pt_g = 0.1374f, pt_b = 1.7251f, pt_rng_low = 0.1591f, pt_rng_high = 0.25f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.1916f, ptm_low_st = 0.5528f, ptm_high = 0.0f, ptm_high_st = 0.2364f, brl_enable = 1, brl_r = -0.5927f, brl_g = -0.612f, brl_b = -0.3952f, brl_c = -0.249f, brl_m = -0.4958f, brl_y = -0.0275f, brl_rng = 0.9291f, hs_rgb_enable = 1, hs_r = 0.0f, hs_g = 1.0f, hs_b = 0.6186f, hs_rgb_rng = 0.747f, hs_cmy_enable = 1, hs_c = 1.0f, hs_m = 0.2956f, hs_y = 0.9997f, hc_enable = 1, hc_r = 1.0f, tone_id = 4, look_exp = 0.62644f;
  }
  else if (lk_sel==5) { 
    tn_Lg = 25.0f, tn_con = 1.5164f, tn_sh = 1.0f, tn_toe = 0.0f, tn_off = 0.0012f, tn_hcon_enable = 1, tn_hcon = -0.9945f, tn_hcon_pv = 4.0f, tn_hcon_st = 4.0f, tn_lcon_enable = 1, tn_lcon = 2.2505f, tn_lcon_w = 2.0f, tn_lcon_pc = 1.0f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.125f, rs_rw = 0.0f, rs_bw = 0.5458f, pt_r = 0.0095f, pt_g = 0.0097f, pt_b = 2.0243f, pt_rng_low = 0.2384f, pt_rng_high = 0.2702f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.3887f, ptm_low_st = 0.9385f, ptm_high = -0.0598f, ptm_high_st = 0.2382f, brl_enable = 1, brl_r = -0.7634f, brl_g = -0.7468f, brl_b = -0.3492f, brl_c = -0.2396f, brl_m = -0.4972f, brl_y = -0.1009f, brl_rng = 0.9867f, hs_rgb_enable = 1, hs_r = 0.0143f, hs_g = 1.0f, hs_b = 0.7485f, hs_rgb_rng = 1.0f, hs_cmy_enable = 1, hs_c = 1.0f, hs_m = 0.8949f, hs_y = 1.0f, hc_enable = 1, hc_r = 1.0f, tone_id = 5, look_exp = 0.64703f;
  }
  else if (lk_sel==6) { 
    tn_Lg = 24.8586f, tn_con = 1.9766f, tn_sh = 0.0011f, tn_toe = 0.0051f, tn_off = 0.02f, tn_hcon_enable = 1, tn_hcon = -0.3466f, tn_hcon_pv = 2.4442f, tn_hcon_st = 3.9832f, tn_lcon_enable = 1, tn_lcon = 1.7653f, tn_lcon_w = 2.0f, tn_lcon_pc = 0.999f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.248f, rs_rw = 0.0055f, rs_bw = 0.3635f, pt_r = 0.1008f, pt_g = 0.1629f, pt_b = 0.4179f, pt_rng_low = 0.176f, pt_rng_high = 0.25f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.1172f, ptm_low_st = 0.4472f, ptm_high = -0.3404f, ptm_high_st = 0.2744f, brl_enable = 1, brl_r = -0.648f, brl_g = -0.8557f, brl_b = -0.5961f, brl_c = 0.0262f, brl_m = -0.4999f, brl_y = 0.4995f, brl_rng = 0.8901f, hs_rgb_enable = 1, hs_r = 0.0f, hs_g = 0.9056f, hs_b = 0.7554f, hs_rgb_rng = 0.2501f, hs_cmy_enable = 1, hs_c = 0.7671f, hs_m = 0.5511f, hs_y = 0.8805f, hc_enable = 1, hc_r = 1.0f, tone_id = 6, look_exp = 0.61052f;
  }
  else if (lk_sel==7) { 
    tn_Lg = 24.7549f, tn_con = 1.6841f, tn_sh = 0.0007f, tn_toe = 0.0023f, tn_off = 0.0445f, tn_hcon_enable = 1, tn_hcon = -0.7392f, tn_hcon_pv = 3.9535f, tn_hcon_st = 0.0003f, tn_lcon_enable = 1, tn_lcon = 2.932f, tn_lcon_w = 2.0f, tn_lcon_pc = 1.0f, cwp = 0, cwp_rng = 0.5f, rs_sa = 0.1679f, rs_rw = 0.0005f, rs_bw = 0.4037f, pt_r = 0.0675f, pt_g = 0.1077f, pt_b = 2.427f, pt_rng_low = 0.2204f, pt_rng_high = 0.3794f, ptl_enable = 1, ptm_enable = 1, ptm_low = 0.1325f, ptm_low_st = 0.6234f, ptm_high = -0.0262f, ptm_high_st = 0.2234f, brl_enable = 1, brl_r = -0.5478f, brl_g = -0.5678f, brl_b = -0.4139f, brl_c = -0.1189f, brl_m = -0.2142f, brl_y = 0.0035f, brl_rng = 0.9518f, hs_rgb_enable = 1, hs_r = 0.0763f, hs_g = 1.0f, hs_b = 0.4187f, hs_rgb_rng = 1.0f, hs_cmy_enable = 1, hs_c = 1.0f, hs_m = 0.0022f, hs_y = 0.9972f, hc_enable = 1, hc_r = 1.0f, tone_id = 7, look_exp = 0.6463f;
  }

  






  float tsk_Lg = tn_Lg, tsk_con = tn_con, tsk_sh = tn_sh, tsk_toe = tn_toe, tsk_off = tn_off;
  float tsk_hcon = tn_hcon_enable ? tn_hcon : 0.0f, tsk_hcon_pv = tn_hcon_pv, tsk_hcon_st = tn_hcon_st;
  float tsk_lcon = tn_lcon_enable ? tn_lcon : 0.0f, tsk_lcon_w = tn_lcon_w, tsk_lcon_pc = tn_lcon_pc;

  
  if (ts_sel==0) { 
  }
  if (ts_sel==1) { 
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    tn_con = tn_con*1.15f;
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
  }
  else if (ts_sel==2) { 
    tn_Lg = 11.1f, tn_con = 1.4f, tn_sh = 0.5f, tn_toe = 0.003f, tn_off = 0.005f, tn_hcon_enable = 0, tn_hcon = 0.0f, tn_hcon_pv = 1.0f, tn_hcon_st = 4.0f, tn_lcon_enable = 0, tn_lcon = 0.0f, tn_lcon_w = 0.5f, tn_lcon_pc = 1.0f;
  }
  else if (ts_sel==3) { 
    tn_Lg = 10.0f, tn_con = 1.0f, tn_sh = 0.245f, tn_toe = 0.02f, tn_off = 0.0f, tn_hcon_enable = 1, tn_hcon = 0.55f, tn_hcon_pv = 0.0f, tn_hcon_st = 2.0f, tn_lcon_enable = 1, tn_lcon = 1.13f, tn_lcon_w = 1.0f, tn_lcon_pc = 1.0f;
  }
  else if (ts_sel==4) { 
    tn_Lg = 10.0f, tn_con = 1.15f, tn_sh = 0.5f, tn_toe = 0.04f, tn_off = 0.0f, tn_hcon_enable = 0, tn_hcon = 1.0f, tn_hcon_pv = 1.0f, tn_hcon_st = 1.0f, tn_lcon_enable = 0, tn_lcon = 1.0f, tn_lcon_w = 0.6f, tn_lcon_pc = 1.0f;
  }
  else if (ts_sel==5) { 
    tn_Lg = 6.0f, tn_con = 1.5f, tn_sh = 0.5f, tn_toe = 0.003f, tn_off = 0.01f, tn_hcon_enable = 1, tn_hcon = 0.25f, tn_hcon_pv = 0.0f, tn_hcon_st = 4.0f, tn_lcon_enable = 1, tn_lcon = 1.0f, tn_lcon_w = 1.0f, tn_lcon_pc = 1.0f;
  }
  else if (ts_sel==6) { 
    tn_Lg = 11.1f, tn_con = 1.05f, tn_sh = 0.5f, tn_toe = 0.1f, tn_off = 0.015f, tn_hcon_enable = 0, tn_hcon = 0.0f, tn_hcon_pv = 0.0f, tn_hcon_st = 2.0f, tn_lcon_enable = 1, tn_lcon = 2.0f, tn_lcon_w = 0.2f, tn_lcon_pc = 1.0f;
  }
  else if (ts_sel==7) { 
    tn_Lg = 10.42f, tn_con = 1.2f, tn_sh = 0.5f, tn_toe = 0.02f, tn_off = 0.0f, tn_hcon_enable = 0, tn_hcon = 0.0f, tn_hcon_pv = 1.0f, tn_hcon_st = 1.0f, tn_lcon_enable = 0, tn_lcon = 0.0f, tn_lcon_w = 0.6f, tn_lcon_pc = 1.0f;
  }
  else if (ts_sel==8) { 
    tn_Lg = 11.1f, tn_con = 1.15f, tn_sh = 0.5f, tn_toe = 0.04f, tn_off = 0.006f, tn_hcon_enable = 0, tn_hcon = 0.0f, tn_hcon_pv = 0.0f, tn_hcon_st = 0.5f, tn_lcon_enable = 1, tn_lcon = 0.5f, tn_lcon_w = 2.0f, tn_lcon_pc = 0.5f;
  }
  else if (ts_sel==9) { 
    tn_Lg = 6.0f, tn_con = 1.8f, tn_sh = 0.5f, tn_toe = 0.001f, tn_off = 0.015f, tn_hcon_enable = 0, tn_hcon = 0.0f, tn_hcon_pv = 1.0f, tn_hcon_st = 4.0f, tn_lcon_enable = 1, tn_lcon = 1.0f, tn_lcon_w = 1.0f, tn_lcon_pc = 1.0f;
  }
  
  
  
  
  
  
  
  
  
  

  
  
  
  
  const float look_amt = lk_passes == 2 ? (lk_pass == 0 ? 1.0f : 0.0f) : lk_t;
  
  
  
  const float tone_amt = tone_bypass ? 0.0f : look_amt*tone_intensity;

  
  
  
  
  if (look_amt < 1.0f) {
    
    
    
    
    if (ts_sel == 0) {
      tn_Lg = 11.1f + (tn_Lg - 11.1f)*look_amt;
      tn_con = 1.4f + (tn_con - 1.4f)*look_amt;
      tn_sh = 0.5f + (tn_sh - 0.5f)*look_amt;
      tn_toe = 0.003f + (tn_toe - 0.003f)*look_amt;
      tn_off = 0.005f + (tn_off - 0.005f)*look_amt;
      tn_hcon = 0.0f + (tn_hcon - 0.0f)*look_amt;
      tn_hcon_pv = 1.0f + (tn_hcon_pv - 1.0f)*look_amt;
      tn_hcon_st = 4.0f + (tn_hcon_st - 4.0f)*look_amt;
      tn_lcon = 1.0f + (tn_lcon - 1.0f)*look_amt;
      tn_lcon_w = 0.5f + (tn_lcon_w - 0.5f)*look_amt;
      tn_lcon_pc = 1.0f + (tn_lcon_pc - 1.0f)*look_amt;
    }
    else if (ts_sel == 1 && look_amt <= 0.0f) {
      
      
      tn_Lg = 11.1009f, tn_con = 1.4f*1.15f, tn_sh = 0.5f, tn_toe = 0.003f, tn_off = 0.005f,
      tn_hcon = 0.0f, tn_hcon_pv = 1.0f, tn_hcon_st = 4.0f, tn_lcon = 1.0f, tn_lcon_w = 0.5f, tn_lcon_pc = 1.0f;
      tn_hcon_enable = 0; tn_lcon_enable = 1;
    }
    cwp_rng = 0.5f + (cwp_rng - 0.5f)*look_amt;
    rs_sa = 0.35f + (rs_sa - 0.35f)*look_amt;
    rs_rw = 0.25f + (rs_rw - 0.25f)*look_amt;
    rs_bw = 0.55f + (rs_bw - 0.55f)*look_amt;
    pt_r = 0.5f + (pt_r - 0.5f)*look_amt;
    pt_g = 2.0f + (pt_g - 2.0f)*look_amt;
    pt_b = 2.0f + (pt_b - 2.0f)*look_amt;
    pt_rng_low = 0.2f + (pt_rng_low - 0.2f)*look_amt;
    pt_rng_high = 0.8f + (pt_rng_high - 0.8f)*look_amt;
    ptm_low = 0.2f + (ptm_low - 0.2f)*look_amt;
    ptm_low_st = 0.5f + (ptm_low_st - 0.5f)*look_amt;
    ptm_high = -0.8f + (ptm_high - -0.8f)*look_amt;
    ptm_high_st = 0.3f + (ptm_high_st - 0.3f)*look_amt;
    brl_r = -0.5f + (brl_r - -0.5f)*look_amt;
    brl_g = -0.4f + (brl_g - -0.4f)*look_amt;
    brl_b = -0.2f + (brl_b - -0.2f)*look_amt;
    brl_c = 0.0f + (brl_c - 0.0f)*look_amt;
    brl_m = 0.0f + (brl_m - 0.0f)*look_amt;
    brl_y = 0.0f + (brl_y - 0.0f)*look_amt;
    brl_rng = 0.66f + (brl_rng - 0.66f)*look_amt;
    hs_r = 0.35f + (hs_r - 0.35f)*look_amt;
    hs_g = 0.25f + (hs_g - 0.25f)*look_amt;
    hs_b = 0.5f + (hs_b - 0.5f)*look_amt;
    hs_rgb_rng = 0.6f + (hs_rgb_rng - 0.6f)*look_amt;
    hs_c = 0.2f + (hs_c - 0.2f)*look_amt;
    hs_m = 0.2f + (hs_m - 0.2f)*look_amt;
    hs_y = 0.2f + (hs_y - 0.2f)*look_amt;
    hc_r = 0.6f + (hc_r - 0.6f)*look_amt;
    look_exp = 1.0f + (look_exp - 1.0f)*look_amt;
    
    
    tsk_Lg = 11.1f + (tsk_Lg - 11.1f)*look_amt;
    tsk_con = 1.4f + (tsk_con - 1.4f)*look_amt;
    tsk_sh = 0.5f + (tsk_sh - 0.5f)*look_amt;
    tsk_toe = 0.003f + (tsk_toe - 0.003f)*look_amt;
    tsk_off = 0.005f + (tsk_off - 0.005f)*look_amt;
    tsk_hcon = 0.0f + (tsk_hcon - 0.0f)*look_amt;
    tsk_hcon_pv = 1.0f + (tsk_hcon_pv - 1.0f)*look_amt;
    tsk_hcon_st = 4.0f + (tsk_hcon_st - 4.0f)*look_amt;
    tsk_lcon = 1.0f + (tsk_lcon - 1.0f)*look_amt;
    tsk_lcon_w = 0.5f + (tsk_lcon_w - 0.5f)*look_amt;
    tsk_lcon_pc = 1.0f + (tsk_lcon_pc - 1.0f)*look_amt;
  }

  
  
  if (print_tone_sel==1) tone_id = 0;
  else if (print_tone_sel>1) {
    
    
    const int TONE_ORDER[7] = {1, 3, 2, 4, 5, 6, 7};
    int ti = print_tone_sel - 2;
    tone_id = TONE_ORDER[ti < 0 ? 0 : (ti > 6 ? 6 : ti)];
  }
  if (tone_bypass) tone_id = 0;

  
  
  if (_cwp!=4) cwp_rng = _cwp_rng; 
  if (_cwp==0) cwp = 0; 
  else if (_cwp==1) cwp = 1; 
  else if (_cwp==2) cwp = 2; 
  else if (_cwp==3) cwp = 3; 

  
  
  
  
  if (cw_bypass) { cwp = 0; cwp_rng = 0.5f; }


  
  if (display_encoding_preset==0) { 
    display_gamut = 0;
    eotf = 2;
  }
  else if (display_encoding_preset==1) { 
    display_gamut = 0;
    eotf = 1;
  }
  else if (display_encoding_preset==2) { 
    display_gamut = 1;
    eotf = 1;
  }
  else if (display_encoding_preset==3) { 
    display_gamut = 2;
    eotf = 4;
  }
  else if (display_encoding_preset==4) { 
    display_gamut = 2;
    eotf = 5;
  }
  else if (display_encoding_preset==5) { 
    display_gamut = 1;
    eotf = 4;
  }
  #endif

  dctl_float3x3 in_to_xyz;
  if (in_gamut==0) in_to_xyz = identity();
  else if (in_gamut==1) in_to_xyz = matrix_ap0_to_xyz;
  else if (in_gamut==2) in_to_xyz = matrix_ap1_to_xyz;
  else if (in_gamut==3) in_to_xyz = matrix_p3d65_to_xyz;
  else if (in_gamut==4) in_to_xyz = matrix_rec2020_to_xyz;
  else if (in_gamut==5) in_to_xyz = matrix_rec709_to_xyz;
  else if (in_gamut==6) in_to_xyz = matrix_arriwg3_to_xyz;
  else if (in_gamut==7) in_to_xyz = matrix_arriwg4_to_xyz;
  else if (in_gamut==8) in_to_xyz = matrix_redwg_to_xyz;
  else if (in_gamut==9) in_to_xyz = matrix_sonysgamut3_to_xyz;
  else if (in_gamut==10) in_to_xyz = matrix_sonysgamut3cine_to_xyz;
  else if (in_gamut==11) in_to_xyz = matrix_vgamut_to_xyz;
  else if (in_gamut==12) in_to_xyz = matrix_bmdwg_to_xyz;
  else if (in_gamut==13) in_to_xyz = matrix_egamut_to_xyz;
  else if (in_gamut==14) in_to_xyz = matrix_egamut2_to_xyz;
  else if (in_gamut==15) in_to_xyz = matrix_davinciwg_to_xyz;

  float3 crv_val = make_float3(0.0f, 0.0f, 0.0f);
  float2 pos = make_float2(p_X, p_Y);
  float2 res = make_float2(p_Width, p_Height);

  
  if (crv_enable == 1) {
    
    
    
    
    const float crv_ox = res.x*(1.0f - crv_size)*0.5f;
    float crv_x = oetf_filmlight_tlog(
      clampf((pos.x - crv_ox)/(res.x*crv_size), 0.0f, 1.0f));
    crv_val = make_float3(crv_x, crv_x, crv_x);
    if (trim_con != 0.0f && !trim_con_bypass) {
      const float cvc_f = _fmaxf(0.0f, 1.0f + trim_con);
      const float cvc_p = clampf(trim_piv, 0.001f, 0.999f);
      crv_val.x = con_scene(crv_val.x, cvc_f, cvc_p);
      crv_val.y = con_scene(crv_val.y, cvc_f, cvc_p);
      crv_val.z = con_scene(crv_val.z, cvc_f, cvc_p);
    }
    
    
    
    if (trim_ovl != 0.0f && !trim_con_bypass)
      crv_val = overlay_scene(crv_val, trim_ovl, OVL_CGAIN);
    crv_val *= look_exp; 
  }

  
  const float fc_code = 0.2126f*rgb.x + 0.7152f*rgb.y + 0.0722f*rgb.z;
  
  rgb = linearize(rgb, in_oetf);
  
  dctl_float3x3 wb_m = identity();

  








  {
    
    
    
    
    
    
    const int wb_k_on = wb_kelvin >= 1800.0f && wb_kelvin <= 20000.0f &&
                        _fabs(wb_kelvin - 6504.0f) > 0.5f;
    const int wb_on = !wb_bypass && (wb_preset > 0 || wb_k_on ||
                                     _fabs(wb_temp) > 1.0e-6f ||
                                     _fabs(wb_tint) > 1.0e-6f);
    if (wb_on) {
      
      const float T_base = wb_preset > 0 ? wb_preset_kelvin(wb_preset)
                                         : (wb_k_on ? wb_kelvin : 6504.0f);
      
      
      
      
      
      
      
      
      
      
      
      
      
      
      const float mired = clampf((1.0e6f/T_base)*_exp2f(-0.9f*wb_temp),
                                 1.0e6f/25000.0f, 1.0e6f/1667.0f);
      const float T_eff = 1.0e6f/mired;
      
      
      
      
      
      
      
      const float duv_max = 0.012f + 0.020f*smootherstep(2200.0f, 5200.0f, T_eff);
      
      
      const float duv = wb_tint*duv_max;

      
      
      
      
      
      const float3 w_src = wb_xy_to_XYZ(wb_white_xy(T_eff, duv));
      const float3 w_dst = wb_xy_to_XYZ(wb_locus_xy(6504.0f));

      
      
      const dctl_float3x3 cat = mat3_mul(mat3_inv(in_to_xyz),
                                    mat3_mul(wb_cat(w_src, w_dst), in_to_xyz));
      rgb = vdot(cat, rgb);
      wb_m = cat;
    }
  }


  
  
  
  
  
  
  
  
  float fc_stops = 0.0f;
  if (fc_overlay == 1) {
    const float fc_lin = linearize(make_float3(fc_code, fc_code, fc_code), in_oetf).x;
    fc_stops = _log2f(_fmaxf(fc_lin, 1.0e-6f)/0.18f);
  }

  





  if (trim_con != 0.0f && !trim_con_bypass) {
    const float con_f = _fmaxf(0.0f, 1.0f + trim_con);
    const float con_pv = clampf(trim_piv, 0.001f, 0.999f);
    rgb.x = con_scene(rgb.x, con_f, con_pv);
    rgb.y = con_scene(rgb.y, con_f, con_pv);
    rgb.z = con_scene(rgb.z, con_f, con_pv);
  }

  





  if (trim_ovl != 0.0f && !trim_con_bypass)
    rgb = overlay_scene(rgb, trim_ovl, OVL_CGAIN);

  






  if ((col_weight != 0.0f || col_dens != 0.0f) && !col_bypass)
    rgb = density_pair(rgb, col_weight, col_dens);

  




  if (trim_mp != 0.0f && !trim_mid_bypass)
    rgb = mid_purity(rgb, trim_mp, trim_mp_pv);

  







  rgb *= look_exp;


  










  const float TS_LG[10][8] = {
    {0.0000f, 0.0000f, 0.0000f, 0.0000f, 0.0000f, 0.0000f, 0.0000f, 0.0000f},
    {0.0000f, 8.2412f, 12.8172f, 5.1995f, 25.9942f, 26.0770f, 25.7316f, 25.6292f},
    {0.0000f, 9.5543f, 12.3120f, 7.6504f, 20.0309f, 18.0989f, 18.3826f, 19.2027f},
    {0.0000f, 7.8474f, 10.9680f, 5.6533f, 20.1857f, 18.5869f, 18.8505f, 19.3240f},
    {0.0000f, 8.2423f, 10.8463f, 6.4548f, 18.3555f, 16.9961f, 17.0692f, 17.6663f},
    {0.0000f, 4.0208f, 5.9843f, 2.7268f, 12.3391f, 12.9052f, 12.6585f, 12.3024f},
    {0.0000f, 9.4212f, 12.3629f, 7.4058f, 20.7064f, 18.7135f, 19.1296f, 19.8134f},
    {0.0000f, 8.7657f, 11.3964f, 6.9554f, 18.9224f, 17.3485f, 17.4883f, 18.1811f},
    {0.0000f, 9.2702f, 12.4002f, 7.0642f, 20.7572f, 18.7818f, 19.1415f, 19.8886f},
    {0.0000f, 3.9770f, 6.0143f, 2.6955f, 12.7898f, 13.3356f, 13.1402f, 12.7236f}};
  if (ts_sel >= 1 && ts_sel <= 9 && look_amt > 0.5f && look_preset >= 1 && look_preset <= 7)
    tn_Lg = TS_LG[ts_sel][look_preset];

  






  const float ts_x1 = _powf(2.0f, 6.0f*tn_sh + 4.0f);
  const float ts_y1 = tn_Lp/100.0f;
  const float ts_x0 = 0.18f + tn_off;
  const float ts_y0 = tn_Lg/100.0f*(1.0f + tn_gb*_log2f(ts_y1));
  const float ts_s0 = compress_toe_quadratic(ts_y0, tn_toe, 1);
  const float ts_s10 = ts_x0*(_powf(ts_s0, -1.0f/tn_con) - 1.0f);
  const float ts_m1 = ts_y1/_powf(ts_x1/(ts_x1 + ts_s10), tn_con);
  const float ts_m2 = compress_toe_quadratic(ts_m1, tn_toe, 1);
  const float ts_s = ts_x0*(_powf(ts_s0/ts_m2, -1.0f/tn_con) - 1.0f);
  const float ts_dsc = eotf==4 ? 0.01 : eotf==5 ? 0.1 : 100.0f/tn_Lp;

  
  const float pt_cmp_Lf = pt_hdr*_fminf(1.0f, (tn_Lp - 100.0f)/900.0f);
  
  const float s_Lp100 = ts_x0*(_powf((tn_Lg/100.0f), -1.0f/tn_con) - 1.0f);
  const float ts_s1 = ts_s*pt_cmp_Lf + s_Lp100*(1.0f - pt_cmp_Lf);


  
  rgb = vdot(in_to_xyz, rgb);
  rgb = vdot(matrix_xyz_to_p3d65, rgb);



  
  
  float3 rs_w = make_float3(rs_rw, 1.0f - rs_rw - rs_bw, rs_bw);
  float sat_L = rgb.x*rs_w.x + rgb.y*rs_w.y + rgb.z*rs_w.z;
  rgb = sat_L*rs_sa + rgb*(1.0f - rs_sa);
  
  
  
  
  
  
  
  
  float sk_w_scene = 0.0f, sk_wl_scene = 0.0f;
  if (((trim_skin_sat != 0.0f || trim_skin > 0.0f) && !skin_col_bypass) ||
      ((skin_hi != 0.0f || skin_mid != 0.0f || skin_sh != 0.0f) && !skin_light_bypass) || skin_zones == 1) {
    
    
    
    
    
    const dctl_float3x3 sk_pre = mat3_mul(matrix_xyz_to_p3d65, mat3_mul(in_to_xyz, wb_m));
    const float2 skm = skin_mask_spatial(p_TexR, p_TexG, p_TexB, p_X, p_Y, p_Height, in_oetf, sk_pre,
                                         rs_sa, rs_w, look_exp, skin_soft,
                                         (trim_skin_sat != 0.0f || trim_skin > 0.0f) ? 1 : 0,
                                         (skin_hi != 0.0f || skin_mid != 0.0f || skin_sh != 0.0f || skin_zones == 1) ? 1 : 0);
    sk_w_scene = skm.x;
    sk_wl_scene = skm.y;
  }

  






















  
  
  
  
  
  
  
  
  
  float skz_x = 0.0f, skz_s1 = 0.0f, skz_s2 = 0.0f;
  if (sk_wl_scene > 0.0f) {
    const float Ys = 0.2289746f*rgb.x + 0.6917385f*rgb.y + 0.0792869f*rgb.z;
    skz_x = _log2f(_fmaxf(Ys, 1.0e-10f)/0.18f) - skin_piv;
    const float Tm = SKL_T*_powf(3.0f, (skin_soft - 0.5f)*2.0f);
    const float T1 = _fmaxf(Tm, SKL_K*_fabs(skin_mid - skin_sh));
    const float T2 = _fmaxf(Tm, SKL_K*_fabs(skin_hi - skin_mid));
    skz_s1 = smootherstep(SKL_B1 - 0.5f*T1, SKL_B1 + 0.5f*T1, skz_x);
    skz_s2 = smootherstep(SKL_B2 - 0.5f*T2, SKL_B2 + 0.5f*T2, skz_x);
  }
  if ((skin_hi != 0.0f || skin_mid != 0.0f || skin_sh != 0.0f) && sk_wl_scene > 0.0f && !skin_light_bypass) {
    const float sl = skin_sh*(1.0f - skz_s1) + skin_mid*(skz_s1 - skz_s2) + skin_hi*skz_s2;
    rgb = rgb*_exp2f(SKL_A*sl*sk_wl_scene);
  }
  
  const float3 tsk_in = rgb;
  const float3 tsk_crv_in = crv_val;


  
  rgb += tn_off;
  
  
  float sh_fl = tn_off;
  if (crv_enable == 1) crv_val += tn_off;


  


  if (tn_lcon_enable) {
    float mcon_m = _powf(2.0f, -tn_lcon);
    float mcon_w = tn_lcon_w/4.0f;
    mcon_w *= mcon_w;

    
    const float mcon_cnst_sc = compress_toe_cubic(ts_x0, mcon_m, mcon_w, 1)/ts_x0;
    rgb *= mcon_cnst_sc;

    sh_fl *= mcon_cnst_sc;
    sh_fl = sh_fl*(sh_fl*sh_fl + mcon_m*mcon_w)/(sh_fl*sh_fl + mcon_w);

    
    float mcon_nm = hypotf3(clampminf3(rgb, 0.0f))/SQRT3;
    float mcon_sc = (mcon_nm*mcon_nm + mcon_m*mcon_w)/(mcon_nm*mcon_nm + mcon_w);

    if (tn_lcon_pc > 0.0f) {
      

      
      float3 mcon_rgb = rgb;
      mcon_rgb.x = compress_toe_cubic(rgb.x, mcon_m, mcon_w, 0);
      mcon_rgb.y = compress_toe_cubic(rgb.y, mcon_m, mcon_w, 0);
      mcon_rgb.z = compress_toe_cubic(rgb.z, mcon_m, mcon_w, 0);

      
      float mcon_mx = fmaxf3(rgb);
      float mcon_mn = fminf3(rgb);
      float mcon_ch = clampf(1.0f - sdivf(mcon_mn, mcon_mx), 0.0, 1.0);
      mcon_ch = _powf(mcon_ch, 4.0f*tn_lcon_pc);
      rgb = mcon_sc*rgb*mcon_ch + mcon_rgb*(1.0f - mcon_ch);
    }
    else { 
      rgb = mcon_sc*rgb;
    }
    
    if (crv_enable == 1) {
      crv_val *= mcon_cnst_sc;
      crv_val = crv_val*(crv_val*crv_val + mcon_m*mcon_w)/(crv_val*crv_val + mcon_w);
    }
  }


  
  float tsn = hypotf3(clampminf3(rgb, 0.0f))/SQRT3;

  
  
  
  
  
  
  
  
  float hd_sat;
  {
    float hs_mx = _fmaxf(rgb.x, _fmaxf(rgb.y, rgb.z));
    float hs_mn = _fminf(rgb.x, _fminf(rgb.y, rgb.z));
    hd_sat = hs_mx > 1.0e-9f ? clampf((hs_mx - hs_mn)/hs_mx, 0.0f, 1.0f) : 0.0f;
  }
  
  
  
  
  
  float hd_sat_s;
  {
    const float hk = 0.05f*(_fabs(rgb.x) + _fabs(rgb.y) + _fabs(rgb.z))/3.0f + 1.0e-9f;
    const float smx = smooth_max2(smooth_max2(rgb.x, rgb.y, hk), rgb.z, hk);
    const float smn = smooth_min2(smooth_min2(rgb.x, rgb.y, hk), rgb.z, hk);
    hd_sat_s = smx > 1.0e-9f ? smooth_min2((smx - smn)/smx, 1.0f, 0.05f) : 0.0f;
    hd_sat_s = _fmaxf(hd_sat_s, 0.0f);
  }
  
  if (crv_enable == 1) crv_val = clampminf3(crv_val, 0.0f);
  
  float ts_pt = _sqrtf(_fmaxf(0.0f, rgb.x*rgb.x*pt_r + rgb.y*rgb.y*pt_g + rgb.z*rgb.z*pt_b));

  
  rgb = sdivf3f(clampminf3(rgb, -2.0f), tsn);



  
  if (tn_hcon_enable) {
    float hcon_p = _powf(2.0f, tn_hcon);
    tsn = contrast_high(tsn, hcon_p, tn_hcon_pv, tn_hcon_st, 0);
    ts_pt = contrast_high(ts_pt, hcon_p, tn_hcon_pv, tn_hcon_st, 0);
    sh_fl = contrast_high(sh_fl, hcon_p, tn_hcon_pv, tn_hcon_st, 0);
    
    if (crv_enable == 1) crv_val = make_float3(
      contrast_high(crv_val.x, hcon_p, tn_hcon_pv, tn_hcon_st, 0),
      contrast_high(crv_val.y, hcon_p, tn_hcon_pv, tn_hcon_st, 0),
      contrast_high(crv_val.z, hcon_p, tn_hcon_pv, tn_hcon_st, 0));
  }

  
  tsn = compress_hyperbolic_power(tsn, ts_s, tn_con);
  ts_pt = compress_hyperbolic_power(ts_pt, ts_s1, tn_con);
  sh_fl = compress_hyperbolic_power(sh_fl, ts_s, tn_con);
  
  if (crv_enable == 1) crv_val = make_float3(
    compress_hyperbolic_power(crv_val.x, ts_s, tn_con),
    compress_hyperbolic_power(crv_val.y, ts_s, tn_con),
    compress_hyperbolic_power(crv_val.z, ts_s, tn_con));

  









  float ts_m2_e = ts_m2, tn_toe_e = tn_toe, ts_y0_e = ts_y0;
  if (ts_sel != 0 && ts_intensity < 1.0f) {
    const float k = _clampf(ts_intensity, 0.0f, 1.0f);
    const ts_out A = ts_core(tsk_in, tsk_crv_in, crv_enable == 1, pt_r, pt_g, pt_b,
                             tsk_Lg, tsk_con, tsk_sh, tsk_toe, tsk_off,
                             tsk_hcon, tsk_hcon_pv, tsk_hcon_st,
                             tsk_lcon, tsk_lcon_w, tsk_lcon_pc, tn_Lp, tn_gb, pt_hdr);
    const float tsnB = compress_toe_quadratic(tsn*ts_m2, tn_toe, 0);
    const float shB = compress_toe_quadratic(sh_fl*ts_m2, tn_toe, 0);
    tsn = ts_mix(A.tsn, tsnB, k);
    sh_fl = ts_mix(A.sh, shB, k);
    rgb = A.r + (rgb - A.r)*k;
    ts_pt = A.pt + (ts_pt - A.pt)*k;
    if (crv_enable == 1) {
      const float3 crvB = make_float3(compress_toe_quadratic(crv_val.x*ts_m2, tn_toe, 0),
                                      compress_toe_quadratic(crv_val.y*ts_m2, tn_toe, 0),
                                      compress_toe_quadratic(crv_val.z*ts_m2, tn_toe, 0));
      crv_val = make_float3(ts_mix(A.crv.x, crvB.x, k), ts_mix(A.crv.y, crvB.y, k), ts_mix(A.crv.z, crvB.z, k));
    }
    ts_y0_e = A.y0 + (ts_y0 - A.y0)*k;
    ts_m2_e = 1.0f; tn_toe_e = 0.0f;
  }


  
  float opp_cy = rgb.x - rgb.z;
  float opp_gm = rgb.y - (rgb.x + rgb.z)/2.0f;
  float ach_d = _sqrtf(_fmaxf(0.0f, opp_cy*opp_cy + opp_gm*opp_gm))/SQRT3;

  
  ach_d = (1.25f)*compress_toe_quadratic(ach_d, 0.25f, 0);

  
  float hue = _fmod(_atan2f(opp_cy, opp_gm) + PI + 1.10714931f, 2.0f*PI);

  
  
  float3 ha_rgb = make_float3(
    gauss_window(hue_offset(hue, 0.1f), 0.9f),
    gauss_window(hue_offset(hue, 4.3f), 0.9f),
    gauss_window(hue_offset(hue, 2.3f), 0.9f));

  
  
  
  float3 ha_cmy = make_float3(
    gauss_window(hue_offset(hue, 3.3f), 0.6f),
    gauss_window(hue_offset(hue, 1.3f), 0.6f),
    gauss_window(hue_offset(hue, -1.2), 0.6f));


  
  
  
  
  
  
  
  
  
  
  
  
  
  const float onset_eff = col_bypass ? 0.0f : col_onset;
  float pt_rng_low_eff = clampf(pt_rng_low*_exp2f(1.6f*onset_eff), 0.02f, 0.98f);
  float ts_pt_cmp = 1.0f - _powf(ts_pt, 1.0f/pt_rng_low_eff);

  float pt_rng_high_f = _fminf(1.0f, ach_d/1.2f);
  pt_rng_high_f *= pt_rng_high_f;
  pt_rng_high_f = pt_rng_high < 1.0f ? 1.0f - pt_rng_high_f : pt_rng_high_f;
  ts_pt_cmp = _powf(ts_pt_cmp, pt_rng_high)*(1.0f - pt_rng_high_f) + ts_pt_cmp*pt_rng_high_f;

  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  if (col_ptw != 1.0f && !col_bypass)
    ts_pt_cmp = spowf(ts_pt_cmp, _exp2f(1.35f*(col_ptw - 1.0f)));

  






  if (trim_hp != 0.0f && !trim_hl_bypass) {
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    float hp_t = trim_hp >= 0.0f ? _powf(trim_hp, 2.5f) : -_powf(-trim_hp, 2.5f);
    const float hp_k = _exp2f(-5.6f*hp_t);
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    if (hp_k < 1.0f) {
      
      
      const float hp_x0 = 0.05f + 0.25f*(1.0f - hp_k)*(1.0f - hp_k);
      const float hp_x = _fmaxf(ts_pt_cmp, 0.0f);
      if (hp_x >= hp_x0) ts_pt_cmp = _powf(hp_x, hp_k);
      else {
        const float hp_v0 = _powf(hp_x0, hp_k), hp_s0 = hp_k*hp_v0/hp_x0;
        const float hp_b = (hp_s0*hp_x0 - hp_v0)/(hp_x0*hp_x0);
        const float hp_a = (2.0f*hp_v0 - hp_s0*hp_x0)/hp_x0;
        ts_pt_cmp = hp_a*hp_x + hp_b*hp_x*hp_x;
      }
    } else {
      ts_pt_cmp = spowf(ts_pt_cmp, hp_k);
    }
  }


  


  float brl_f = 1.0f;
  if (brl_enable) {
    brl_f = -brl_r*ha_rgb.x - brl_g*ha_rgb.y - brl_b*ha_rgb.z - brl_c*ha_cmy.x - brl_m*ha_cmy.y - brl_y*ha_cmy.z;
    brl_f = (1.0f - ach_d)*brl_f + 1.0f - brl_f;
    brl_f = softplus(brl_f, 0.25f); 
    
    
    float brl_ts = brl_f > 1.0f ? 1.0f - ts_pt : ts_pt; 
    float brl_lim = spowf(brl_ts, 1.0f - brl_rng);
    brl_f = brl_f*brl_lim + 1.0f - brl_lim;
    





    if (trim_br != 0.0f && !trim_hl_bypass) brl_f = 1.0f + (brl_f - 1.0f)*(1.0f - trim_br);

    brl_f = _fmaxf(0.0f, _fminf(2.0f, brl_f)); 
  }



  




  
  
  
  
  
  

  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  if (trim_hs != 0.0f && !trim_hl_bypass) {
    ptm_high = trim_hs > 0.0f
             ? ptm_high*(1.0f - trim_hs*0.78f)                  
             : ptm_high*(1.0f - trim_hs*0.85f);                  
  }

  float ptm_sc = 1.0f;
  if (ptm_enable) {
    
    float ptm_ach_d = complement_power(ach_d, ptm_low_st);
    ptm_sc = sigmoid_cubic(ptm_ach_d, ptm_low*(1.0f - ts_pt));

    
    ptm_ach_d = complement_power(ach_d, ptm_high_st)*(1.0f - ts_pt) + ach_d*ach_d*ts_pt;
    ptm_sc *= sigmoid_cubic(ptm_ach_d, ptm_high*ts_pt);
    
    
    
    ptm_sc = smooth_relu(ptm_sc, 0.02f + 0.15f*_fmaxf(-trim_hs, 0.0f)*(trim_hl_bypass ? 0.0f : 1.0f));

  }


  
  ha_rgb *= ach_d;
  ha_cmy *= (1.5f)*compress_toe_quadratic(ach_d, 0.5f, 0); 


  


  if (hc_enable) {
    float hc_ts = 1.0f - ts_pt;
    
    
    float hc_c = (1.0f - ach_d)*hc_ts + ach_d*(1.0f - hc_ts);
    hc_c *= ha_rgb.x;
    hc_ts *= hc_ts;
    
    float hc_f = hc_r*(hc_c - 2.0f*hc_c*hc_ts) + 1.0f;
    rgb = make_float3(rgb.x, rgb.y*hc_f, rgb.z*hc_f);
  }



  



  
  if (hs_rgb_enable) {
    float3 hs_rgb = ha_rgb*_powf(ts_pt, 1.0f/hs_rgb_rng);
    float3 hsf = make_float3(hs_rgb.x*hs_r, hs_rgb.y*-hs_g, hs_rgb.z*-hs_b);
    hsf = make_float3(hsf.z - hsf.y, hsf.x - hsf.z, hsf.y - hsf.x);
    rgb += hsf;
  }

  
  if (hs_cmy_enable) {
    float3 hs_cmy = ha_cmy*(1.0f - ts_pt);
    float3 hsf = make_float3(hs_cmy.x*-hs_c, hs_cmy.y*hs_m, hs_cmy.z*hs_y);
    hsf = make_float3(hsf.z - hsf.y, hsf.x - hsf.z, hsf.y - hsf.x);
    rgb += hsf;
  }

  
  rgb *= brl_f;

  
  ts_pt_cmp *= ptm_sc;
  rgb = rgb*ts_pt_cmp + 1.0f - ts_pt_cmp;

  
  
  
  
  
  if (col_chroma != 1.0f && !col_bypass) {
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    rgb = chroma_sub(rgb, col_chroma);
  }

  
  sat_L = rgb.x*rs_w.x + rgb.y*rs_w.y + rgb.z*rs_w.z;
  rgb = (sat_L*rs_sa - rgb)/(rs_sa - 1.0f);

  
  float3 cwp_rgb = rgb;
  if (display_gamut==0) {
    if (cwp==1) cwp_rgb = vdot(matrix_p3_to_rec709_d60, rgb);
    if (cwp==2) cwp_rgb = vdot(matrix_p3_to_rec709_d55, rgb);
    if (cwp==3) cwp_rgb = vdot(matrix_p3_to_rec709_d50, rgb);
    rgb = vdot(matrix_p3_to_rec709_d65, rgb);
    if (cwp==0) cwp_rgb = rgb;
  }
  else if (display_gamut>=1) {
    if (cwp==1) cwp_rgb = vdot(matrix_p3_to_p3_d60, rgb);
    if (cwp==2) cwp_rgb = vdot(matrix_p3_to_p3_d55, rgb);
    if (cwp==3) cwp_rgb = vdot(matrix_p3_to_p3_d50, rgb);
  }

  
  float cwp_f = _powf(tsn, 1.0f - cwp_rng);
  rgb = cwp_rgb*cwp_f + rgb*(1.0f - cwp_f);

  
  float3 crv_rgb = crv_val;
  float3 crv_rgb_cwp = crv_rgb;
  if (crv_enable == 1) {
    if (display_gamut==0) {
      if (cwp==1) crv_rgb_cwp = vdot(matrix_p3_to_rec709_d60, crv_rgb);
      if (cwp==2) crv_rgb_cwp = vdot(matrix_p3_to_rec709_d55, crv_rgb);
      if (cwp==3) crv_rgb_cwp = vdot(matrix_p3_to_rec709_d50, crv_rgb);
      crv_rgb = vdot(matrix_p3_to_rec709_d65, crv_rgb);
      if (cwp==0) crv_rgb_cwp = crv_rgb;
    }
    else if (display_gamut>=1) {
      if (cwp==1) crv_rgb_cwp = vdot(matrix_p3_to_p3_d60, crv_rgb);
      if (cwp==2) crv_rgb_cwp = vdot(matrix_p3_to_p3_d55, crv_rgb);
      if (cwp==3) crv_rgb_cwp = vdot(matrix_p3_to_p3_d50, crv_rgb);
    }

    float crv_rgb_cwp_f = _powf(crv_val.y, 1.0f - cwp_rng);
    crv_rgb = crv_rgb_cwp*crv_rgb_cwp_f + crv_rgb*(1.0f - crv_rgb_cwp_f);
  }


  
  if (ptl_enable) {
    float sum0 = softplus_constraint(rgb.x, 0.2f, -100.0f, -0.3f) + rgb.y + softplus_constraint(rgb.z, 0.2f, -100.0f, -0.3f);
    rgb.x = softplus(rgb.x, 0.06f);
    rgb.y = softplus(rgb.y, 0.06f);
    rgb.z = softplus(rgb.z, 0.04f);

    
    
    
    
    
    
    const float ptl_r = sdivf(sum0, rgb.x + rgb.y + rgb.z);
    float ptl_norm = 1.0f - smooth_relu(1.0f - ptl_r, 0.02f);
    rgb *= ptl_norm;
  }

  
  tsn *= ts_m2_e; 
  tsn = compress_toe_quadratic(tsn, tn_toe_e, 0);

  
  
  if (tone_id > 0 && tone_amt > 0.0f)
    {
      
      
      const float pt_lim = 0.500f + 0.500f*smootherstep(0.450f, 0.850f, hd_sat);
      rgb *= print_tone(tsn/ts_y1, tone_id, tone_amt, pt_lim);
    }


  









  if (trim_sh != 0.0f && !trim_hl_bypass) {
    sh_fl = compress_toe_quadratic(sh_fl*ts_m2_e, tn_toe_e, 0);
    const float sh_p = 0.3f*ts_y0_e;
    const float sh_wg = 1.0f/(1.0f + spowf(_fmaxf(ts_y0_e - sh_fl, 1e-6f)/sh_p, 3.0f));
    
    
    
    
    
    
    float sh_x = tsn - sh_fl;
    float sh_w = _fmaxf(sh_x, 0.0f)/sh_p;
    sh_w = 1.0f/(1.0f + sh_w*sh_w*sh_w);
    sh_w = smooth_relu((sh_w - sh_wg)/(1.0f - sh_wg), 0.05f);
    tsn = sh_fl + sh_x*_exp2f(1.5f*trim_sh*sh_w);
  }
  tsn *= ts_dsc; 

  if (crv_enable == 1) {
    
    
    
    const float crv_n = crv_val.y;
    float3 crv_rt = crv_n > 1e-6f
      ? make_float3(crv_rgb.x/crv_n, crv_rgb.y/crv_n, crv_rgb.z/crv_n)
      : make_float3(1.0f, 1.0f, 1.0f);
    float crv_ach = compress_toe_quadratic(crv_n*ts_m2_e, tn_toe_e, 0);

    
    
    if (tone_id > 0 && tone_amt > 0.0f)
      crv_rt *= print_tone(crv_ach/ts_y1, tone_id, tone_amt, 0.0f);

    if (trim_sh != 0.0f && !trim_hl_bypass) {
      const float shc_p = 0.3f*ts_y0_e;
      const float shc_wg = 1.0f/(1.0f + spowf(_fmaxf(ts_y0_e - sh_fl, 1e-6f)/shc_p, 3.0f));
      float shc_x = crv_ach - sh_fl;
      float shc_w = _fmaxf(shc_x, 0.0f)/shc_p;
      shc_w = 1.0f/(1.0f + shc_w*shc_w*shc_w);
      shc_w = smooth_relu((shc_w - shc_wg)/(1.0f - shc_wg), 0.05f);
      crv_ach = sh_fl + shc_x*_exp2f(1.5f*trim_sh*shc_w);
    }
    crv_rgb = crv_rt*crv_ach*ts_dsc;
    
    
    
    
    crv_rgb = clampf3(crv_rgb, 0.0f, 1.0f);
    
    if (eotf == 4) crv_rgb *= 10.0f;
  }

  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  
  if (trim_hd != 0.0f && !trim_hl_bypass) {
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    const float hd_w = hd_sat_s*smootherstep(0.0f, 0.25f, hd_sat_s);
    const float hd_a = 1.35f*_fmaxf(trim_hd, 0.0f)*hd_w;
    const float hd_e = -0.1203f;                               
    const float hd_W = _sqrtf(1.7162f*1.7162f + 4.3403f*hd_a*hd_a); 
    float lvl = tsn/_fmaxf(ts_dsc*ts_y1, 1.0e-6f);
    float hi = smootherstep(hd_e - hd_W, hd_e, _log2f(_fmaxf(lvl, 1.0e-6f)));
    tsn *= _exp2f(-hd_a*hi);
  }

  
  rgb *= tsn;

  






  if ((trim_skin > 0.0f || trim_skin_sat != 0.0f) && !skin_col_bypass) {
    const float sk_pk = ts_y1*ts_dsc;   
    const int sk_p3 = display_gamut >= 1;
    float3 sk = rgb/sk_pk;
    if (trim_skin > 0.0f) sk = skin_line(sk, sk_p3, trim_skin, sk_w_scene);
    









    
    
    
    
    if (trim_skin_sat != 0.0f && sk_w_scene > 0.0f) {
      const float3 sat = chroma_sub(sk, 1.0f + trim_skin_sat);
      sk = sk + (sat - sk)*sk_w_scene;
    }
    rgb = sk*sk_pk;
  }

  
  if (out_clamp) rgb = clampf3(rgb, 0.0f, 1.0f);

  
  if (display_gamut==2) {
    rgb = clampminf3(rgb, 0.0f);
    rgb = vdot(matrix_p3_to_rec2020, rgb);
  }


  
  float eotf_p = 2.0f + eotf * 0.2f;
  if ((eotf > 0) && (eotf < 4)) rgb = spowf3(rgb, 1.0f/eotf_p);
  else if (eotf == 4) rgb = eotf_pq(rgb, 1);
  else if (eotf == 5) rgb = eotf_hlg(rgb, 1);

  if (crv_enable == 1) {
    if ((eotf > 0) && (eotf < 4)) crv_rgb = spowf3(crv_rgb, 1.0f/eotf_p);
    else if (eotf == 4) crv_rgb = eotf_pq(crv_rgb, 1);
    else if (eotf == 5) crv_rgb = eotf_hlg(crv_rgb, 1);
  }

  
  
  
  if (lk_passes == 2) {
    if (lk_pass == 0) { lk_full = rgb; lk_full_crv = crv_rgb; continue; }
    rgb = rgb + (lk_full - rgb)*lk_t;
    crv_rgb = crv_rgb + (lk_full_crv - crv_rgb)*lk_t;
  }

  
  
  
  
  
  if (fc_overlay == 1) {
    float3 fc = fc_color(fc_stops);                 
    if ((eotf > 0) && (eotf < 4)) fc = spowf3(fc, 1.0f/eotf_p);
    else if (eotf == 4) fc = eotf_pq(fc, 1);
    else if (eotf == 5) fc = eotf_hlg(fc, 1);
    rgb = fc;

    
    
    
    
    const float fhf = res.y;
    const float pxf = pos.x + 0.5f;
    const float pyf = pos.y + 0.5f;
    const float chf = 0.052f*fhf, gpf = 0.006f*fhf, cwf = 0.085f*fhf;
    const float x0f = 0.030f*fhf, pdf = 0.012f*fhf;
    const float bwf = _fmaxf(1.0f, 0.0020f*fhf);
    const float blkf = 13.0f*chf + 12.0f*gpf;
    const float y0f = 0.5f*(fhf - blkf);
    const float ccxf = x0f + 0.5f*cwf;
    const float sfg = _fmaxf(1.0f, _floorf(0.006f*fhf + 0.5f));
    if (legend == 1 &&
        pxf < x0f + cwf + pdf + 2.0f &&
        pyf > y0f - pdf - 2.0f && pyf < y0f + blkf + pdf + 2.0f) {
      float dpanf = ovl_rrect_sdf(pxf, pyf, ccxf, 0.5f*fhf,
                                  0.5f*cwf + pdf, 0.5f*blkf + pdf, 0.25f*chf);
      float apanf = ovl_cov(dpanf);
      rgb.x = ovl_mix(rgb.x, 0.0800f, apanf);
      rgb.y = ovl_mix(rgb.y, 0.0800f, apanf);
      rgb.z = ovl_mix(rgb.z, 0.0800f, apanf);
      for (int i = 0; i < 13; ++i) {
        float cyf = y0f + (float)i*(chf + gpf) + 0.5f*chf;
        
        
        
        
        float aout = ovl_cov(ovl_rrect_sdf(pxf, pyf, ccxf, cyf,
                                           0.5f*cwf + bwf, 0.5f*chf + bwf,
                                           0.12f*chf + bwf));
        if (aout <= 0.0f) continue;
        rgb.x = ovl_mix(rgb.x, 0.3200f, aout);
        rgb.y = ovl_mix(rgb.y, 0.3200f, aout);
        rgb.z = ovl_mix(rgb.z, 0.3200f, aout);
        float a = ovl_cov(ovl_rrect_sdf(pxf, pyf, ccxf, cyf,
                                        0.5f*cwf, 0.5f*chf, 0.12f*chf));
        if (a <= 0.0f) continue;
        int z = 12 - i;                               
        float3 sw = fc_color((float)(z - 6));
        if ((eotf > 0) && (eotf < 4)) sw = spowf3(sw, 1.0f/eotf_p);
        else if (eotf == 4) sw = eotf_pq(sw, 1);
        else if (eotf == 5) sw = eotf_hlg(sw, 1);
        rgb.x = ovl_mix(rgb.x, sw.x, a);
        rgb.y = ovl_mix(rgb.y, sw.y, a);
        rgb.z = ovl_mix(rgb.z, sw.z, a);
        
        
        
        float lyf = cyf - 2.5f*sfg;
        float tc;
        if (z > 6)      tc = _fmaxf(ovl_glyph_cov(pxf, pyf, ccxf - 3.5f*sfg, lyf, sfg, 10),
                                    ovl_glyph_cov(pxf, pyf, ccxf + 0.5f*sfg, lyf, sfg, z - 6));
        else if (z < 6) tc = _fmaxf(ovl_glyph_cov(pxf, pyf, ccxf - 3.5f*sfg, lyf, sfg, 11),
                                    ovl_glyph_cov(pxf, pyf, ccxf + 0.5f*sfg, lyf, sfg, 6 - z));
        else            tc = ovl_glyph_cov(pxf, pyf, ccxf - 1.5f*sfg, lyf, sfg, 0);
        float lum_sw = 0.2126f*sw.x + 0.7152f*sw.y + 0.0722f*sw.z;
        float tcol = (lum_sw > 0.5000f) ? 0.0f : 0.9000f;
        rgb.x = ovl_mix(rgb.x, tcol, tc);
        rgb.y = ovl_mix(rgb.y, tcol, tc);
        rgb.z = ovl_mix(rgb.z, tcol, tc);
      }
    }
  }

  
  
  
  
  
  
  
  
  
  
  
  
  if (skin_zones == 1) {
    float3 zcs = make_float3(0.20f, 0.45f, 1.00f);
    float3 zcm = make_float3(0.25f, 0.85f, 0.35f);
    float3 zch = make_float3(1.00f, 0.85f, 0.15f);
    float3 zcn = make_float3(0.30f, 0.30f, 0.30f);
    zcs = spowf3(zcs, 2.4f); zcm = spowf3(zcm, 2.4f); zch = spowf3(zch, 2.4f); zcn = spowf3(zcn, 2.4f);
    if ((eotf > 0) && (eotf < 4)) {
      zcs = spowf3(zcs, 1.0f/eotf_p); zcm = spowf3(zcm, 1.0f/eotf_p);
      zch = spowf3(zch, 1.0f/eotf_p); zcn = spowf3(zcn, 1.0f/eotf_p);
    } else if (eotf == 4) {                       
      zcs = eotf_pq(zcs*0.02f, 1); zcm = eotf_pq(zcm*0.02f, 1);
      zch = eotf_pq(zch*0.02f, 1); zcn = eotf_pq(zcn*0.02f, 1);
    } else if (eotf == 5) {
      zcs = eotf_hlg(zcs, 1); zcm = eotf_hlg(zcm, 1); zch = eotf_hlg(zch, 1); zcn = eotf_hlg(zcn, 1);
    }
    const float lc = _clampf(0.2126f*rgb.x + 0.7152f*rgb.y + 0.0722f*rgb.z, 0.0f, 1.0f);
    const float3 zc = zcs*(1.0f - skz_s1) + zcm*(skz_s1 - skz_s2) + zch*skz_s2;
    const float3 grey = zcn*(0.35f + 0.9f*lc);
    rgb = grey + (zc*(0.6f + 0.8f*lc) - grey)*_clampf(sk_wl_scene, 0.0f, 1.0f);
    if (legend == 1)
      rgb = draw_zones_legend(rgb, (float)p_X, (float)p_Y, res.x, res.y,
                              SKL_B1 + skin_piv, SKL_B2 + skin_piv, zcs, zcm, zch, zcn);
  }

  
  if (skin_check == 1) {
    
    float3 sl = make_float3(spowf(rgb.x, eotf_p), spowf(rgb.y, eotf_p), spowf(rgb.z, eotf_p));

    
    const float A0 = -0.012061f, B0 = 0.014794f;
    const float rac = 0.73728f;   
    const float rbc = 0.67559f;   

    float3 pq  = skchk_probe(sl);
    float  Lnc = _fmaxf(pq.z, 1.0e-4f);
    float  anc = pq.x / Lnc - A0;
    float  bnc = pq.y / Lnc - B0;

    float uc = anc*rac + bnc*rbc;
    float vc = bnc*rac - anc*rbc;
    float nc = _sqrtf(_fmaxf(uc*uc + vc*vc, 0.0f));
    float tc = clampf(vc / (nc + uc + 1.0e-9f), -1.0e6f, 1.0e6f);   

    const float K_YELLOW_DEG = 4.5f, K_FULL_DEG = 25.0f, K_RAMP_GAMMA = 0.45f;
    float tY = _sinf(K_YELLOW_DEG*0.0087266463f)/_cosf(K_YELLOW_DEG*0.0087266463f);
    float tF = _sinf(K_FULL_DEG  *0.0087266463f)/_cosf(K_FULL_DEG  *0.0087266463f);
    float stepv = _powf(smootherstep(tY, tF, _fabs(tc)), K_RAMP_GAMMA);

    float ccon = smootherstep(0.015f, 0.038f, nc);
    float sgnc = (tc >= 0.0f) ? 1.0f : 0.0f;
    float wGc  = stepv * sgnc;
    float wMc  = stepv * (1.0f - sgnc);
    float wYc  = 1.0f - stepv;
    float ccx = wYc*1.000f + wGc*0.000f + wMc*1.000f;
    float ccy = wYc*0.950f + wGc*1.000f + wMc*0.000f;
    float ccz = wYc*0.000f + wGc*0.120f + wMc*1.000f;

    float Vc = _fmaxf(rgb.x, _fmaxf(rgb.y, rgb.z));
    const float K_PAINT_LEVEL = 0.52f;

    
    
    
    
    
    
    
    float3 klab = ovl_oklab(sl);
    float  kC   = _sqrtf(klab.y*klab.y + klab.z*klab.z);
    float  pwc  = ovl_band(kC, 0.010f, 0.032f) * (1.0f - ovl_band(kC, 0.085f, 0.115f));
    pwc = pwc * smootherstep(0.004f, 0.020f, Vc);
    pwc = pwc * ccon;

    rgb.x = rgb.x + pwc*(ccx*K_PAINT_LEVEL - rgb.x);
    rgb.y = rgb.y + pwc*(ccy*K_PAINT_LEVEL - rgb.y);
    rgb.z = rgb.z + pwc*(ccz*K_PAINT_LEVEL - rgb.z);

    if (legend == 1)
      rgb = draw_check_legend(rgb, (float)p_X, (float)p_Y, res.x, res.y);
  }

  if (crv_enable == 1) {
    
    
    const float crv_h = res.y*crv_size;
    const float crv_my = res.y*(1.0f + crv_size)*0.5f;
    const float crv_mx = res.x*(1.0f - crv_size)*0.5f;
    float3 crv_rgb_dst = make_float3(crv_my-pos.y-crv_rgb.x*crv_h, crv_my-pos.y-crv_rgb.y*crv_h, crv_my-pos.y-crv_rgb.z*crv_h);
    float crv_w0 = 1.1f; 
    crv_rgb_dst.x = _expf(-crv_rgb_dst.x*crv_rgb_dst.x*crv_w0);
    crv_rgb_dst.y = _expf(-crv_rgb_dst.y*crv_rgb_dst.y*crv_w0);
    crv_rgb_dst.z = _expf(-crv_rgb_dst.z*crv_rgb_dst.z*crv_w0);
    float crv_lm = eotf < 4 ? 1.0f : 0.5f; 
    crv_rgb_dst = clampf3(crv_rgb_dst, 0.0f, 1.0f);
    
    
    
    
    
    if (pos.x < crv_mx || pos.x > crv_mx + res.x*crv_size)
      crv_rgb_dst = make_float3(0.0f, 0.0f, 0.0f);
    float crv_a = _fmaxf(crv_rgb_dst.x, _fmaxf(crv_rgb_dst.y, crv_rgb_dst.z));
    rgb = rgb*(1.0f - crv_a) + crv_lm*crv_rgb_dst;
  }

  if (trial_mark == 1) rgb = trial_wm(rgb, (float)p_X, (float)p_Y, (float)p_Height);
  return rgb;
  }
  if (trial_mark == 1) rgb = trial_wm(rgb, (float)p_X, (float)p_Y, (float)p_Height);
  return rgb;
}

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
    DctlTex tr = {src, D.rowFloatsSrc, W, H, 0, D.flipY};
    DctlTex tg = {src, D.rowFloatsSrc, W, H, 1, D.flipY};
    DctlTex tb = {src, D.rowFloatsSrc, W, H, 2, D.flipY};
    const device float* s = src + row * D.rowFloatsSrc + x * 4;
    device float* d = dst + row * D.rowFloatsDst + x * 4;
    const float3 o = dctl_transform(P, W, H, x, y, tr, tg, tb);
    d[0] = o.x; d[1] = o.y; d[2] = o.z; d[3] = s[3];
}
