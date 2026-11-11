// =============================================================================
//  NODE_DRT — Texture stage (Grain + Halation), Metal kernels
// -----------------------------------------------------------------------------
//  Baked after NodeTextureMath.h into gen/texture_metal_src.h. Same passes and
//  same arithmetic as textureCPU() in NodeTexture.cpp, compiled with fast-math
//  off. Buffers are bottom-up OFX rows; row strides come in TexArgs.
// =============================================================================

inline int tx_ci(int v, int a, int b) { return v < a ? a : (v > b ? b : v); }

// 1. halation source of every pixel
kernel void tx_src(constant TexArgs& A [[buffer(0)]], const device float* src [[buffer(1)]],
                   device float* S [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W || y >= A.H) return;
    const device float* p = src + y * A.srcRow + x * 4;
    const float Y = A.Yr * tx_decode(A.oetf, p[0]) + A.Yg * tx_decode(A.oetf, p[1]) + A.Yb * tx_decode(A.oetf, p[2]);
    S[y * A.W + x] = tx_halSource(Y, A.halThr);
}

// 2. 2 x 2 average onto the half grid
kernel void tx_down(constant TexArgs& A [[buffer(0)]], const device float* S [[buffer(1)]],
                    device float* Sd [[buffer(2)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W2 || y >= A.H2) return;
    const int x0 = min(2 * x, A.W - 1), x1 = min(2 * x + 1, A.W - 1);
    const int y0 = min(2 * y, A.H - 1), y1 = min(2 * y + 1, A.H - 1);
    Sd[y * A.W2 + x] = ((S[y0 * A.W + x0] + S[y0 * A.W + x1]) + (S[y1 * A.W + x0] + S[y1 * A.W + x1])) * 0.25f;
}

// 3. horizontal pass, six separable terms
kernel void tx_hh(constant TexArgs& A [[buffer(0)]], const device float* G [[buffer(1)]],
                  const device float* K [[buffer(2)]], device float* tmp6 [[buffer(3)]],
                  uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W2 || y >= A.H2) return;
    const int R = A.halR, N = 2 * R + 1;
    for (int r = 0; r < 6; ++r) {
        const device float* k = K + r * N;
        float a = 0.0f;
        for (int i = -R; i <= R; ++i) a += k[i + R] * G[y * A.W2 + tx_ci(x + i, 0, A.W2 - 1)];
        tmp6[(r * A.H2 + y) * A.W2 + x] = a;
    }
}

// 4. vertical pass, terms summed with their weights -> B
kernel void tx_hv(constant TexArgs& A [[buffer(0)]], const device float* tmp6 [[buffer(1)]],
                  const device float* K [[buffer(2)]], device float* Bg [[buffer(3)]],
                  const device float* G [[buffer(4)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W2 || y >= A.H2) return;
    const int R = A.halR, N = 2 * R + 1;
    float b = 0.0f;
    for (int r = 0; r < 6; ++r) {
        const device float* k = K + r * N;
        float a = 0.0f;
        for (int j = -R; j <= R; ++j) a += k[j + R] * tmp6[(r * A.H2 + tx_ci(y + j, 0, A.H2 - 1)) * A.W2 + x];
        b += a * A.halNorm[r];
    }
    Bg[y * A.W2 + x] = A.halSoftR > 0 ? metal::fmax(b - G[y * A.W2 + x], 0.0f) : b;
}

// 4b. halo softness: normalised gaussian, horizontal then vertical
kernel void tx_sh(constant TexArgs& A [[buffer(0)]], const device float* Bg [[buffer(1)]],
                  const device float* K [[buffer(2)]], device float* tmp [[buffer(3)]],
                  uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W2 || y >= A.H2) return;
    const int SR = A.halSoftR;
    float a = 0.0f;
    for (int i = -SR; i <= SR; ++i) a += K[i + SR] * Bg[y * A.W2 + tx_ci(x + i, 0, A.W2 - 1)];
    tmp[y * A.W2 + x] = a;
}
kernel void tx_sv(constant TexArgs& A [[buffer(0)]], const device float* tmp [[buffer(1)]],
                  const device float* K [[buffer(2)]], device float* Bg [[buffer(3)]],
                  uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W2 || y >= A.H2) return;
    const int SR = A.halSoftR;
    float a = 0.0f;
    for (int j = -SR; j <= SR; ++j) a += K[j + SR] * tmp[tx_ci(y + j, 0, A.H2 - 1) * A.W2 + x];
    Bg[y * A.W2 + x] = a;
}

// 5. grain noise, horizontal pass over the padded band (3 channels)
// Each threadgroup covers a run of consecutive pixels of one row. The noise it
// needs - its pixels plus GR on each side - is drawn ONCE into threadgroup
// memory, then every pixel sums its taps from there. Same values, same order of
// summation as drawing each tap on the spot (which drew every noise value
// 2 GR + 1 times), so the result is bit for bit the same.
kernel void tx_gh(constant TexArgs& A [[buffer(0)]], const device float* K [[buffer(1)]],
                  device float* T [[buffer(2)]], threadgroup float* nb [[threadgroup(0)]],
                  uint2 tid [[thread_position_in_threadgroup]], uint2 tgid [[threadgroup_position_in_grid]],
                  uint2 tgs [[threads_per_threadgroup]])
{
    const int GR = A.grR, Hp = A.H + 2 * GR;
    const int TW = (int)tgs.x;
    const int x0 = (int)tgid.x * TW;
    const int yy = (int)tgid.y;
    const int y = yy - GR;
    const int span = TW + 2 * GR;
    for (int c = 0; c < 3; ++c) {
        const unsigned int sd = A.seed + (unsigned int)c * GX_CH_SEED;
        for (int k = (int)tid.x; k < span; k += TW) nb[c * span + k] = tx_gauss(x0 - GR + k, y, sd);
    }
    metal::threadgroup_barrier(metal::mem_flags::mem_threadgroup);
    const int x = x0 + (int)tid.x;
    if (x >= A.W || yy >= Hp) return;
    for (int c = 0; c < 3; ++c) {
        float a = 0.0f;
        for (int i = -GR; i <= GR; ++i) a += K[i + GR] * nb[c * span + (int)tid.x + i + GR];
        T[(c * Hp + yy) * A.W + x] = a;
    }
}

// 6. per pixel: vertical grain pass, halation + grain, re-encode the change
kernel void tx_final(constant TexArgs& A [[buffer(0)]], const device float* src [[buffer(1)]],
                     device float* dst [[buffer(2)]], const device float* S [[buffer(3)]],
                     const device float* Bg [[buffer(4)]], const device float* GK [[buffer(5)]],
                     const device float* T [[buffer(6)]], uint2 gid [[thread_position_in_grid]])
{
    const int x = (int)gid.x, y = (int)gid.y;
    if (x >= A.W || y >= A.H) return;
    const device float* p = src + y * A.srcRow + x * 4;
    device float* d = dst + y * A.dstRow + x * 4;
    TxRGB c = {tx_decode(A.oetf, p[0]), tx_decode(A.oetf, p[1]), tx_decode(A.oetf, p[2])};
    const TxRGB c0 = c;
    float S0 = 0.0f, B = 0.0f;
    if (A.halOn) {
        S0 = S[y * A.W + x];
        if (A.halfRes) {
            const float fy = (y + 0.5f) * 0.5f - 0.5f;
            const int y0 = tx_ci((int)metal::floor(fy), 0, A.H2 - 1), y1 = min(y0 + 1, A.H2 - 1);
            const float wy = metal::fmin(metal::fmax(fy - y0, 0.0f), 1.0f);
            const float fx = (x + 0.5f) * 0.5f - 0.5f;
            const int x0 = tx_ci((int)metal::floor(fx), 0, A.W2 - 1), x1 = min(x0 + 1, A.W2 - 1);
            const float wx = metal::fmin(metal::fmax(fx - x0, 0.0f), 1.0f);
            const float a = Bg[y0 * A.W2 + x0] * (1.0f - wx) + Bg[y0 * A.W2 + x1] * wx;
            const float b = Bg[y1 * A.W2 + x0] * (1.0f - wx) + Bg[y1 * A.W2 + x1] * wx;
            B = a * (1.0f - wy) + b * wy;
        } else {
            B = Bg[y * A.W + x];
        }
    }
    float z0 = 0.0f, z1 = 0.0f, z2 = 0.0f;
    if (A.grOn) {
        const int GR = A.grR, Hp = A.H + 2 * GR;
        for (int j = 0; j <= 2 * GR; ++j) {
            const float k = GK[j];
            z0 += k * T[(0 * Hp + y + j) * A.W + x];
            z1 += k * T[(1 * Hp + y + j) * A.W + x];
            z2 += k * T[(2 * Hp + y + j) * A.W + x];
        }
    }
    if (A.halSoftR > 0) S0 = 0.0f;   // B already is the (diffused) halo
    c = tx_pixel(A.halOn, A.halS, A.kw0, A.kw1, A.kw2, A.grOn, A.grScale, A.grSat, A.grSh, A.grMd, A.grHi,
                 A.Yr, A.Yg, A.Yb, c, S0, B, z0, z1, z2);
    d[0] = c.r == c0.r ? p[0] : p[0] + (tx_encode(A.oetf, c.r) - tx_encode(A.oetf, c0.r));
    d[1] = c.g == c0.g ? p[1] : p[1] + (tx_encode(A.oetf, c.g) - tx_encode(A.oetf, c0.g));
    d[2] = c.b == c0.b ? p[2] : p[2] + (tx_encode(A.oetf, c.b) - tx_encode(A.oetf, c0.b));
    d[3] = p[3];
}
