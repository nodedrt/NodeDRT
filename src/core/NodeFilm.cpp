// NODE_DRT — film print tables: loading. Compiled inside NodeTexture.cpp's
// translation unit (see the end of that file), like NodeDensity.cpp.
#include "NodeFilm.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <vector>

namespace nodeone {
namespace {

struct FilmData {
    bool tried = false;
    int n = 0, count = 0;
    std::vector<uint16_t> half;
    std::vector<float> flt;
};

float halfToFloat(uint16_t h)
{
    const uint32_t s = (uint32_t)(h & 0x8000u) << 16, e = (h >> 10) & 0x1Fu, m = h & 0x3FFu;
    uint32_t f;
    if (e == 0) {
        if (m == 0) f = s;
        else {   // subnormal
            int ee = -1; uint32_t mm = m;
            do { ++ee; mm <<= 1; } while (!(mm & 0x400u));
            f = s | (uint32_t)(127 - 15 - ee) << 23 | (mm & 0x3FFu) << 13;
        }
    } else if (e == 31) f = s | 0x7F800000u | (m << 13);
    else f = s | (e + 112u) << 23 | (m << 13);
    float out;
    std::memcpy(&out, &f, 4);
    return out;
}

std::string filmPath()
{
    // the plugin binary is Contents/MacOS/NodeDRT.ofx: resources are next door
    Dl_info info;
    if (!dladdr(reinterpret_cast<const void*>(&filmPath), &info) || !info.dli_fname) return std::string();
    std::string p = info.dli_fname;
    for (int i = 0; i < 2; ++i) {
        const size_t k = p.find_last_of('/');
        if (k == std::string::npos) return std::string();
        p.erase(k);
    }
    return p + "/Resources/Film/film_tables.bin";
}

FilmData& film()
{
    static std::mutex m;
    static FilmData d;
    std::lock_guard<std::mutex> lock(m);
    if (d.tried) return d;
    d.tried = true;
    const char* env = std::getenv("NODEDRT_FILM_TABLES");   // tests outside a bundle
    const std::string path = env ? std::string(env) : filmPath();
    FILE* f = path.empty() ? nullptr : std::fopen(path.c_str(), "rb");
    if (!f) return d;
    char magic[8];
    int32_t hdr[2];
    if (std::fread(magic, 1, 8, f) == 8 && std::memcmp(magic, "NDFILM01", 8) == 0 && std::fread(hdr, 4, 2, f) == 2 &&
        hdr[0] > 1 && hdr[0] <= 129 && hdr[1] > 0 && hdr[1] <= 64) {
        const size_t vals = (size_t)hdr[0] * hdr[0] * hdr[0] * 3 * hdr[1];
        d.half.resize(vals);
        if (std::fread(d.half.data(), 2, vals, f) == vals) {
            d.flt.resize(vals);
            for (size_t i = 0; i < vals; ++i) d.flt[i] = halfToFloat(d.half[i]);
            d.n = hdr[0];
            d.count = hdr[1];
        } else {
            d.half.clear();
        }
    }
    std::fclose(f);
    return d;
}

} // namespace

const float* filmTablesCPU(int& n)
{
    FilmData& d = film();
    n = d.n;
    return d.n ? d.flt.data() : nullptr;
}

const void* filmTablesHalf(int& n, unsigned long& bytes)
{
    FilmData& d = film();
    n = d.n;
    bytes = (unsigned long)d.half.size() * 2u;
    return d.n ? d.half.data() : nullptr;
}

} // namespace nodeone
