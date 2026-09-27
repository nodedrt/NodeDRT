// =============================================================================
//  NODE_ONE OFX — DCTL compatibility layer, Metal Shading Language
// -----------------------------------------------------------------------------
//  Compiled at runtime (MTLDevice newLibraryWithSource) with fast-math OFF,
//  so results follow IEEE-754 single precision like the CPU path.
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
inline float _powf(float x, float y) { return metal::pow(x, y); }
inline float _sqrtf(float x) { return metal::sqrt(x); }
inline float _rsqrtf(float x) { return metal::rsqrt(x); }
// Metal has no cbrt(). Same expression as the CPU layer, so both agree.
inline float _cbrtf(float x) { return metal::copysign(metal::pow(metal::fabs(x), 1.0f / 3.0f), x); }
inline float _expf(float x) { return metal::exp(x); }
inline float _exp2f(float x) { return metal::exp2(x); }
inline float _exp10f(float x) { return metal::exp10(x); }
inline float _logf(float x) { return metal::log(x); }
inline float _log2f(float x) { return metal::log2(x); }
inline float _log10f(float x) { return metal::log10(x); }
inline float _sinf(float x) { return metal::sin(x); }
inline float _cosf(float x) { return metal::cos(x); }
inline float _tanf(float x) { return metal::tan(x); }
inline float _asinf(float x) { return metal::asin(x); }
inline float _acosf(float x) { return metal::acos(x); }
inline float _atanf(float x) { return metal::atan(x); }
inline float _atan2f(float y, float x) { return metal::atan2(y, x); }
inline float _sinhf(float x) { return metal::sinh(x); }
inline float _coshf(float x) { return metal::cosh(x); }
inline float _tanhf(float x) { return metal::tanh(x); }
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
