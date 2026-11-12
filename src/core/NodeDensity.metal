// =============================================================================
//  NODE_DRT — Density Pro, Metal kernels
// -----------------------------------------------------------------------------
//  Baked after NodeTextureMath.h and NodeDensityMath.h into
//  gen/density_metal_src.h. Same passes and same arithmetic as densityCPU() in
//  NodeDensity.cpp, compiled with fast-math off. Buffers are OFX rows.
// =============================================================================

inline int dp_ci(int v, int a, int b) { return v < a ? a : (v > b ? b : v); }

// 1. the selection key: the picture in DaVinci Intermediate, clamped to 0..1
kernel void dp_key(constant DensArgs& A [[buffer(0)]], const device float* src [[buffer(1)]],
                   device float* K [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W || y >= A.H) return;
    const device float* p = src + y * A.srcRow + x * 4;
    const DpRGB c = dp_toWork(A, p[0], p[1], p[2]);
    device float* k = K + (y * A.W + x) * 3;
    k[0] = dp_clamp01(c.r); k[1] = dp_clamp01(c.g); k[2] = dp_clamp01(c.b);
}

// 2. soft mask: three horizontal + three vertical box passes (~ gaussian).
//  - horizontal: a threadgroup covers a run of one row and reads it once into
//    threadgroup memory; each pixel then sums its 2r + 1 neighbours from there
//    (reading a row from device memory one thread per row was 5x slower);
//  - vertical: running sums over runs of DP_SEG rows of one float column -
//    neighbouring threads read neighbouring floats, a few operations per pixel
//    whatever the radius.
// densityCPU() runs the very same additions in the same order.
constant int DP_SEG = 64;
kernel void dp_boxh(constant DensArgs& A [[buffer(0)]], const device float* in [[buffer(1)]],
                    device float* out [[buffer(2)]], threadgroup float* tb [[threadgroup(0)]],
                    uint2 tid [[thread_position_in_threadgroup]], uint2 tgid [[threadgroup_position_in_grid]],
                    uint2 tgs [[threads_per_threadgroup]])
{
    const int TW = (int)tgs.x, W = A.W, r = A.blurR;
    const int x0 = (int)tgid.x * TW, y = (int)tgid.y;
    const int span = TW + 2 * r;
    const device float* s = in + y * W * 3;
    for (int k = (int)tid.x; k < span; k += TW) {
        const int xs = dp_ci(x0 - r + k, 0, W - 1);
        tb[k * 3 + 0] = s[xs * 3 + 0];
        tb[k * 3 + 1] = s[xs * 3 + 1];
        tb[k * 3 + 2] = s[xs * 3 + 2];
    }
    metal::threadgroup_barrier(metal::mem_flags::mem_threadgroup);
    const int x = x0 + (int)tid.x;
    if (x >= W || y >= A.H) return;
    const float inv = 1.0f / (float)(2 * r + 1);
    for (int c = 0; c < 3; ++c) {
        float acc = 0.0f;
        for (int i = 0; i <= 2 * r; ++i) acc += tb[((int)tid.x + i) * 3 + c];
        out[(y * W + x) * 3 + c] = acc * inv;
    }
}
kernel void dp_boxv(constant DensArgs& A [[buffer(0)]], const device float* in [[buffer(1)]],
                    device float* out [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int i = (int)gid.x, y0 = (int)gid.y * DP_SEG;   // i: one float column (pixel x, channel c)
    const int W = A.W, H = A.H;
    if (i >= W * 3 || y0 >= H) return;
    const int y1 = min(y0 + DP_SEG, H), r = A.blurR;
    const float inv = 1.0f / (float)(2 * r + 1);
    float acc = 0.0f;
    for (int y = y0 - r; y <= y0 + r; ++y) acc += in[dp_ci(y, 0, H - 1) * W * 3 + i];
    for (int y = y0; y < y1; ++y) {
        out[y * W * 3 + i] = acc * inv;
        acc += in[min(y + r + 1, H - 1) * W * 3 + i] - in[max(y - r, 0) * W * 3 + i];
    }
}

// 3. the selection field on every 2nd pixel of every 2nd row - RELIEF's grid.
// Three floats per point, so the box passes of step 2 blur it (step 4) with
// A.W / A.H set to the grid size by the host.
kernel void dp_grid(constant DensArgs& A [[buffer(0)]], const device float* K [[buffer(1)]],
                    device float* G [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int Wl = (A.W - 1) / 2 + 2, Hl = (A.H - 1) / 2 + 2;
    const int lx = (int)gid.x, ly = (int)gid.y;
    if (lx >= Wl || ly >= Hl) return;
    const int x = min(lx * 2, A.W - 1), y = min(ly * 2, A.H - 1);
    const device float* k = K + (y * A.W + x) * 3;
    const DpField f = dp_field(A, k[0], k[1], k[2]);
    device float* g = G + (ly * Wl + lx) * 3;
    g[0] = f.f0; g[1] = f.f1; g[2] = f.f2;
}

// 5. per pixel: the blurred field read back (bilinear), times this pixel's own
// saturation weight, then film density on the real pixel.
kernel void dp_apply(constant DensArgs& A [[buffer(0)]], const device float* src [[buffer(1)]],
                     device float* dst [[buffer(2)]], const device float* K [[buffer(3)]],
                     const device float* G [[buffer(4)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W || y >= A.H) return;
    const int Wl = (A.W - 1) / 2 + 2;
    const int lx = x / 2, ly = y / 2;
    const float wx = (float)(x - lx * 2) / 2.0f, wy = (float)(y - ly * 2) / 2.0f;
    const device float* g00 = G + (ly * Wl + lx) * 3;
    const device float* g01 = g00 + 3;
    const device float* g10 = g00 + Wl * 3;
    const device float* g11 = g10 + 3;
    const float f0 = dp_gridLerp(g00[0], g01[0], g10[0], g11[0], wx, wy);
    const float f1 = dp_gridLerp(g00[1], g01[1], g10[1], g11[1], wx, wy);
    const float f2 = dp_gridLerp(g00[2], g01[2], g10[2], g11[2], wx, wy);
    const device float* p = src + y * A.srcRow + x * 4;
    device float* d = dst + y * A.dstRow + x * 4;
    const device float* k = K + (y * A.W + x) * 3;
    const float v = dp_finish(A, k[0], k[1], k[2], f0, f1, f2);
    DpRGB c; c.r = p[0]; c.g = p[1]; c.b = p[2];
    const DpRGB o = dp_apply_value(A, c, v);
    d[0] = o.r; d[1] = o.g; d[2] = o.b; d[3] = p[3];
}
