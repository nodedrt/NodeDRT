// =============================================================================
//  NODE_ONE OFX — DCTL compatibility layer, CPU (C++17)
// -----------------------------------------------------------------------------
//  Lets the DCTL sources compile unchanged as C++. Every DCTL builtin used by
//  the Node_One nodes is provided with IEEE-754 single-precision semantics, the
//  same as the Metal path (fast-math disabled there too).
//  The generated translation units wrap each DCTL in its own namespace, so the
//  seven nodes link into one binary without symbol clashes.
// =============================================================================
#pragma once
#include <cmath>
#include <cstddef>
#include <algorithm>

#define __RESOLVE_VER_MAJOR__ 20
#define __RESOLVE_VER_MINOR__ 0
#define __DEVICE__ static
#define __CONSTANT__ static const
#define __CONSTANTREF__ const
#define __TEXTURE__ ::dctl::Tex
#define __PARAMSREF__ const
#define DEVICE_IS_CPU 1

namespace dctl {

// minimal is_same, so the generated layout assertions need no <type_traits>
template <class A, class B> struct is_same { static const bool value = false; };
template <class A> struct is_same<A, A> { static const bool value = true; };

struct float2 { float x, y; };
struct float3 { float x, y, z; };
struct float4 { float x, y, z, w; };

static inline float2 make_float2(float x, float y) { return float2{x, y}; }
static inline float3 make_float3(float x, float y, float z) { return float3{x, y, z}; }
static inline float4 make_float4(float x, float y, float z, float w) { return float4{x, y, z, w}; }

// ---- vector arithmetic (component-wise, like Metal / CUDA helper_math) ------
#define DCTL_V2(OP)                                                                              \
    static inline float2 operator OP(float2 a, float2 b) { return float2{a.x OP b.x, a.y OP b.y}; } \
    static inline float2 operator OP(float2 a, float s) { return float2{a.x OP s, a.y OP s}; }       \
    static inline float2 operator OP(float s, float2 a) { return float2{s OP a.x, s OP a.y}; }
#define DCTL_V3(OP)                                                                                          \
    static inline float3 operator OP(float3 a, float3 b) { return float3{a.x OP b.x, a.y OP b.y, a.z OP b.z}; } \
    static inline float3 operator OP(float3 a, float s) { return float3{a.x OP s, a.y OP s, a.z OP s}; }         \
    static inline float3 operator OP(float s, float3 a) { return float3{s OP a.x, s OP a.y, s OP a.z}; }
#define DCTL_V4(OP)                                                                                                      \
    static inline float4 operator OP(float4 a, float4 b) { return float4{a.x OP b.x, a.y OP b.y, a.z OP b.z, a.w OP b.w}; } \
    static inline float4 operator OP(float4 a, float s) { return float4{a.x OP s, a.y OP s, a.z OP s, a.w OP s}; }           \
    static inline float4 operator OP(float s, float4 a) { return float4{s OP a.x, s OP a.y, s OP a.z, s OP a.w}; }
DCTL_V2(+) DCTL_V2(-) DCTL_V2(*) DCTL_V2(/)
DCTL_V3(+) DCTL_V3(-) DCTL_V3(*) DCTL_V3(/)
DCTL_V4(+) DCTL_V4(-) DCTL_V4(*) DCTL_V4(/)
#undef DCTL_V2
#undef DCTL_V3
#undef DCTL_V4
static inline float2 operator-(float2 a) { return float2{-a.x, -a.y}; }
static inline float3 operator-(float3 a) { return float3{-a.x, -a.y, -a.z}; }
static inline float4 operator-(float4 a) { return float4{-a.x, -a.y, -a.z, -a.w}; }
template <class V, class S> static inline V& operator+=(V& a, const S& b) { a = a + b; return a; }
template <class V, class S> static inline V& operator-=(V& a, const S& b) { a = a - b; return a; }
template <class V, class S> static inline V& operator*=(V& a, const S& b) { a = a * b; return a; }
template <class V, class S> static inline V& operator/=(V& a, const S& b) { a = a / b; return a; }

// ---- scalar builtins ---------------------------------------------------------
static inline float _fabs(float x) { return std::fabs(x); }
static inline float _powf(float x, float y) { return std::pow(x, y); }
static inline float _sqrtf(float x) { return std::sqrt(x); }
static inline float _rsqrtf(float x) { return 1.0f / std::sqrt(x); }
// Metal has no cbrt(): use the same expression here so both paths agree.
static inline float _cbrtf(float x) { return std::copysign(std::pow(std::fabs(x), 1.0f / 3.0f), x); }
static inline float _expf(float x) { return std::exp(x); }
static inline float _exp2f(float x) { return std::exp2(x); }
static inline float _exp10f(float x) { return std::pow(10.0f, x); }
static inline float _logf(float x) { return std::log(x); }
static inline float _log2f(float x) { return std::log2(x); }
static inline float _log10f(float x) { return std::log10(x); }
static inline float _sinf(float x) { return std::sin(x); }
static inline float _cosf(float x) { return std::cos(x); }
static inline float _tanf(float x) { return std::tan(x); }
static inline float _asinf(float x) { return std::asin(x); }
static inline float _acosf(float x) { return std::acos(x); }
static inline float _atanf(float x) { return std::atan(x); }
static inline float _atan2f(float y, float x) { return std::atan2(y, x); }
static inline float _sinhf(float x) { return std::sinh(x); }
static inline float _coshf(float x) { return std::cosh(x); }
static inline float _tanhf(float x) { return std::tanh(x); }
static inline float _hypotf(float x, float y) { return std::sqrt(x * x + y * y); }
static inline float _fmod(float x, float y) { return std::fmod(x, y); }
static inline float _fmodf(float x, float y) { return std::fmod(x, y); }
static inline float _floorf(float x) { return std::floor(x); }
static inline float _floor(float x) { return std::floor(x); }
static inline float _ceilf(float x) { return std::ceil(x); }
static inline float _ceil(float x) { return std::ceil(x); }
static inline float _truncf(float x) { return std::trunc(x); }
static inline float _round(float x) { return std::round(x); }
static inline float _roundf(float x) { return std::round(x); }
static inline float _fmaxf(float a, float b) { return std::fmax(a, b); }
static inline float _fminf(float a, float b) { return std::fmin(a, b); }
static inline float _fdimf(float a, float b) { return std::fdim(a, b); }
static inline float _fmaf(float a, float b, float c) { return std::fma(a, b, c); }
static inline float _copysignf(float a, float b) { return std::copysign(a, b); }
static inline float _ldexpf(float a, int e) { return std::ldexp(a, e); }
// Metal clamp(): fmin(fmax(x, lo), hi)
static inline float _clampf(float x, float lo, float hi) { return std::fmin(std::fmax(x, lo), hi); }
static inline float _saturatef(float x) { return std::fmin(std::fmax(x, 0.0f), 1.0f); }
static inline float _mix(float a, float b, float t) { return a + (b - a) * t; }
static inline float3 _mix(float3 a, float3 b, float t) { return a + (b - a) * t; }
static inline int _isnan(float x) { return std::isnan(x) ? 1 : 0; }
static inline int _isinf(float x) { return std::isinf(x) ? 1 : 0; }
static inline int _isfinite(float x) { return std::isfinite(x) ? 1 : 0; }

// ---- textures ------------------------------------------------------------------
//  One colour channel of the source image. DCTL coordinates: origin top-left.
//  Reads outside the frame clamp to the nearest edge pixel.
struct Tex {
    const float* base;   // first pixel of the bottom-most buffer row
    ptrdiff_t rowFloats; // floats per buffer row (from OFX rowBytes)
    int w, h, ch;
    int flipY;           // 1: buffer row 0 is the bottom of the frame (OFX)
    const float* film;   // film print tables (NodeFilm), or null
    int filmN;           // grid size of one table (0: none)
};
// FILM PRINT TABLES - same lookup as the Metal prelude (nodeone_film).
#define NODEONE_FILM 1
static inline int nodeone_film_ok(const Tex& t) { return (t.film && t.filmN > 1) ? 1 : 0; }
static inline float3 nodeone_film(const Tex& t, int look, float3 di) {
    const int N = t.filmN;
    const float* T = t.film + (size_t)(look - 1) * (size_t)N * N * N * 3;
    const float fN = (float)(N - 1);
    auto cl = [](float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); };
    const float ur = cl(di.x) * fN, ug = cl(di.y) * fN, ub = cl(di.z) * fN;
    const int r0 = std::min((int)ur, N - 2), g0 = std::min((int)ug, N - 2), b0 = std::min((int)ub, N - 2);
    const float fr = ur - (float)r0, fg = ug - (float)g0, fb = ub - (float)b0;
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    for (int k = 0; k < 8; ++k) {
        const int dr = k >> 2, dg = (k >> 1) & 1, db = k & 1;
        const float w = (dr ? fr : 1.0f - fr) * (dg ? fg : 1.0f - fg) * (db ? fb : 1.0f - fb);
        const float* q = T + ((size_t)((r0 + dr) * N + (g0 + dg)) * N + (b0 + db)) * 3;
        a0 += w * q[0]; a1 += w * q[1]; a2 += w * q[2];
    }
    return make_float3(1.04f / (1.0f + std::exp(-a0)) - 0.02f, 1.04f / (1.0f + std::exp(-a1)) - 0.02f,
                       1.04f / (1.0f + std::exp(-a2)) - 0.02f);
}
static inline float _tex2D(const Tex& t, int x, int y) {
    x = x < 0 ? 0 : (x >= t.w ? t.w - 1 : x);
    y = y < 0 ? 0 : (y >= t.h ? t.h - 1 : y);
    const int row = t.flipY ? (t.h - 1 - y) : y;
    return t.base[row * t.rowFloats + (ptrdiff_t)x * 4 + t.ch];
}

} // namespace dctl
