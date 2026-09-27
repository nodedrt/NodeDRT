// =============================================================================
//  NODE_ONE OFX — 3D LUT kernel (Metal)
// -----------------------------------------------------------------------------
//  Tetrahedral interpolation, the same six-tetrahedron split as the CPU path in
//  NodeOneLut.cpp, so both render identically. Compiled at runtime with
//  fast-math off. The kernel is called node_one_main like the generated ones:
//  each Metal library is built on its own, so the name only has to be unique
//  inside this one, and the build's kernel check then covers this file too.
// =============================================================================
#include <metal_stdlib>

struct LutParams {
    int width, height, rowFloatsSrc, rowFloatsDst;
    int size, pad0, pad1, pad2;
    float dmin0, dmin1, dmin2, dpad0;
    float dmax0, dmax1, dmax2, dpad1;
};

kernel void node_one_main(constant LutParams& P [[buffer(0)]],
                          const device float* src [[buffer(1)]],
                          device float* dst [[buffer(2)]],
                          const device float* lut [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]])
{
    if ((int)gid.x >= P.width || (int)gid.y >= P.height) return;
    const int row = (int)gid.y;
    const device float* s = src + row * P.rowFloatsSrc + (int)gid.x * 4;
    device float* d = dst + row * P.rowFloatsDst + (int)gid.x * 4;

    const int N = P.size;
    const float3 dmin = float3(P.dmin0, P.dmin1, P.dmin2);
    const float3 dmax = float3(P.dmax0, P.dmax1, P.dmax2);
    const float3 t = metal::clamp((float3(s[0], s[1], s[2]) - dmin) / (dmax - dmin), 0.0f, 1.0f);
    const float3 p = t * (float)(N - 1);

    int3 i0 = int3(p);
    i0 = metal::clamp(i0, 0, N - 2);
    const float3 f = p - float3(i0);

    const int sR = 3, sG = N * 3, sB = N * N * 3;
    const int base = i0.x * sR + i0.y * sG + i0.z * sB;
    const float fr = f.x, fg = f.y, fb = f.z;

    int a, b;
    float wA, wB, w000, w111;
    if (fr > fg) {
        if (fg > fb)      { a = sR;      wA = fr - fg; b = sR + sG; wB = fg - fb; w000 = 1.0f - fr; w111 = fb; }
        else if (fr > fb) { a = sR;      wA = fr - fb; b = sR + sB; wB = fb - fg; w000 = 1.0f - fr; w111 = fg; }
        else              { a = sB;      wA = fb - fr; b = sR + sB; wB = fr - fg; w000 = 1.0f - fb; w111 = fg; }
    } else {
        if (fb > fg)      { a = sB;      wA = fb - fg; b = sG + sB; wB = fg - fr; w000 = 1.0f - fb; w111 = fr; }
        else if (fb > fr) { a = sG;      wA = fg - fb; b = sG + sB; wB = fb - fr; w000 = 1.0f - fg; w111 = fr; }
        else              { a = sG;      wA = fg - fr; b = sR + sG; wB = fr - fb; w000 = 1.0f - fg; w111 = fb; }
    }
    const int i111 = base + sR + sG + sB;
    for (int c = 0; c < 3; ++c)
        d[c] = w000 * lut[base + c] + wA * lut[base + a + c] + wB * lut[base + b + c] + w111 * lut[i111 + c];
    d[3] = s[3];
}
