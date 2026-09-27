// =============================================================================
//  NODE_ONE OFX — 3D LUT stage (see NodeOneLut.h)
// =============================================================================
#include "NodeOneLut.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <thread>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#if !defined(_WIN32)
#include <dlfcn.h>
#endif

namespace nodeone {
namespace {

std::string trim(const std::string& s)
{
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

bool isCube(const std::string& n)
{
    if (n.size() < 6) return false;
    std::string e = n.substr(n.size() - 5);
    for (char& c : e) c = (char)std::tolower((unsigned char)c);
    return e == ".cube" && n[0] != '.';
}

std::string homeDir()
{
#if defined(_WIN32)
    const char* h = std::getenv("USERPROFILE");
#else
    const char* h = std::getenv("HOME");
#endif
    return h ? std::string(h) : std::string();
}

// Collects .cube files under `dir`, naming them by their path relative to the
// scan root so two stocks with the same file name stay apart in the menu.
void scanDir(const std::string& dir, const std::string& rel, int depth, std::vector<LutEntry>& out)
{
    if (depth > 4 || out.size() > 4000) return;
#if defined(_WIN32)
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA((dir + "\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        const std::string n = fd.cFileName;
        if (n == "." || n == "..") continue;
        const std::string full = dir + "\\" + n;
        const std::string r = rel.empty() ? n : rel + "/" + n;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) scanDir(full, r, depth + 1, out);
        else if (isCube(n)) out.push_back({r.substr(0, r.size() - 5), full});
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    DIR* d = opendir(dir.c_str());
    if (!d) return;
    while (struct dirent* e = readdir(d)) {
        const std::string n = e->d_name;
        if (n == "." || n == "..") continue;
        const std::string full = dir + "/" + n;
        const std::string r = rel.empty() ? n : rel + "/" + n;
        struct stat st;
        if (stat(full.c_str(), &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) scanDir(full, r, depth + 1, out);
        else if (S_ISREG(st.st_mode) && isCube(n)) out.push_back({r.substr(0, r.size() - 5), full});
    }
    closedir(d);
#endif
}

// Where this plugin binary lives: <...>/NodeOne.ofx.bundle/Contents/MacOS/x.ofx
// so its own resources are two levels up, in Contents/Resources.
std::string bundleResourceDir()
{
#if defined(_WIN32)
    return std::string();
#else
    Dl_info info;
    if (!dladdr((const void*)&bundleResourceDir, &info) || !info.dli_fname) return std::string();
    std::string p = info.dli_fname;
    for (int up = 0; up < 2; ++up) {
        const size_t slash = p.rfind('/');
        if (slash == std::string::npos) return std::string();
        p.resize(slash);
    }
    return p + "/Resources/LUTs";
#endif
}

std::vector<LutEntry> buildCatalog()
{
    std::vector<LutEntry> out;
    const std::string home = homeDir();

    // The LUTs carried inside the bundle come first, so the menu opens on the
    // curated set rather than on everything installed on the machine.
    const std::string res = bundleResourceDir();
    if (!res.empty()) {
        std::vector<LutEntry> bundled;
        scanDir(res, "", 0, bundled);
        std::sort(bundled.begin(), bundled.end(),
                  [](const LutEntry& a, const LutEntry& b) { return a.name < b.name; });
        for (LutEntry& e : bundled) {
            const size_t slash = e.name.rfind('/');
            if (slash != std::string::npos) e.name = e.name.substr(slash + 1);
            e.bundled = true;
            out.push_back(e);
        }
    }
    std::vector<std::string> roots;
#if defined(__APPLE__)
    roots.push_back("/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT");
    if (!home.empty()) roots.push_back(home + "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT");
#elif defined(_WIN32)
    roots.push_back("C:\\ProgramData\\Blackmagic Design\\DaVinci Resolve\\Support\\LUT");
#else
    roots.push_back("/opt/resolve/LUT");
    roots.push_back("/home/resolve/LUT");
#endif
    if (const char* extra = std::getenv("NODEONE_LUT_PATH")) {
        std::string s = extra;
        size_t start = 0;
        while (start <= s.size()) {
            const size_t sep = s.find(':', start);
            const std::string part = s.substr(start, sep == std::string::npos ? std::string::npos : sep - start);
            if (!part.empty()) roots.push_back(part);
            if (sep == std::string::npos) break;
            start = sep + 1;
        }
    }
    std::vector<LutEntry> onDisk;
    for (const std::string& r : roots) scanDir(r, "", 0, onDisk);
    std::sort(onDisk.begin(), onDisk.end(), [](const LutEntry& a, const LutEntry& b) { return a.name < b.name; });
    onDisk.erase(std::unique(onDisk.begin(), onDisk.end(),
                             [](const LutEntry& a, const LutEntry& b) { return a.name == b.name; }),
                 onDisk.end());

    // A LUT already carried in the bundle is not listed twice.
    for (const LutEntry& e : onDisk) {
        bool dup = false;
        for (const LutEntry& b : out) {
            const size_t slash = e.name.rfind('/');
            if (b.name == (slash == std::string::npos ? e.name : e.name.substr(slash + 1))) { dup = true; break; }
        }
        if (!dup) out.push_back(e);
    }
    return out;
}

std::mutex gLutMutex;
std::map<std::string, Lut3D> gLuts;
std::map<std::string, std::string> gLutErrors;

} // namespace

const std::vector<LutEntry>& lutCatalog()
{
    static const std::vector<LutEntry> catalog = buildCatalog();
    return catalog;
}

bool lutParseCube(const std::string& path, Lut3D& out, std::string& error)
{
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        error = "cannot open " + path;
        return false;
    }
    out = Lut3D();
    std::vector<float> data;
    char line[1024];
    long expected = -1;
    while (std::fgets(line, sizeof(line), f)) {
        std::string s = trim(line);
        if (s.empty() || s[0] == '#') continue;
        if (s.compare(0, 11, "LUT_3D_SIZE") == 0) {
            out.size = std::atoi(s.c_str() + 11);
            if (out.size < 2 || out.size > 256) {
                std::fclose(f);
                error = "unsupported LUT_3D_SIZE in " + path;
                return false;
            }
            expected = (long)out.size * out.size * out.size * 3;
            data.reserve((size_t)expected);
            continue;
        }
        if (s.compare(0, 11, "LUT_1D_SIZE") == 0) {
            std::fclose(f);
            error = "1D LUTs are not supported: " + path;
            return false;
        }
        if (s.compare(0, 5, "TITLE") == 0) {
            const size_t q = s.find('"');
            out.title = q == std::string::npos ? trim(s.substr(5)) : s.substr(q + 1, s.rfind('"') - q - 1);
            continue;
        }
        if (s.compare(0, 14, "DOMAIN_MIN") == 0 || s.compare(0, 10, "DOMAIN_MIN") == 0) {
            std::sscanf(s.c_str() + 10, "%f %f %f", &out.domainMin[0], &out.domainMin[1], &out.domainMin[2]);
            continue;
        }
        if (s.compare(0, 10, "DOMAIN_MAX") == 0) {
            std::sscanf(s.c_str() + 10, "%f %f %f", &out.domainMax[0], &out.domainMax[1], &out.domainMax[2]);
            continue;
        }
        if (s.compare(0, 19, "LUT_3D_INPUT_RANGE") == 0) {
            float a = 0.f, b = 1.f;
            if (std::sscanf(s.c_str() + 18, "%f %f", &a, &b) == 2) {
                out.domainMin[0] = out.domainMin[1] = out.domainMin[2] = a;
                out.domainMax[0] = out.domainMax[1] = out.domainMax[2] = b;
            }
            continue;
        }
        if (!(std::isdigit((unsigned char)s[0]) || s[0] == '-' || s[0] == '+' || s[0] == '.')) continue;
        float r, g, b;
        if (std::sscanf(s.c_str(), "%f %f %f", &r, &g, &b) != 3) continue;
        data.push_back(r);
        data.push_back(g);
        data.push_back(b);
    }
    std::fclose(f);
    if (out.size <= 0) {
        error = "no LUT_3D_SIZE in " + path;
        return false;
    }
    if ((long)data.size() != expected) {
        char buf[160];
        std::snprintf(buf, sizeof(buf), "expected %ld values, found %zu", expected, data.size());
        error = std::string(buf) + " in " + path;
        return false;
    }
    for (int i = 0; i < 3; ++i)
        if (!(out.domainMax[i] > out.domainMin[i])) {
            error = "empty input range in " + path;
            return false;
        }
    out.data.swap(data);
    return true;
}

const Lut3D* lutLoad(const std::string& path, std::string& error)
{
    std::lock_guard<std::mutex> lock(gLutMutex);
    auto it = gLuts.find(path);
    if (it != gLuts.end()) return &it->second;
    auto bad = gLutErrors.find(path);
    if (bad != gLutErrors.end()) {
        error = bad->second;
        return nullptr;
    }
    Lut3D lut;
    if (!lutParseCube(path, lut, error)) {
        gLutErrors[path] = error;
        return nullptr;
    }
    return &(gLuts[path] = std::move(lut));
}

// Tetrahedral interpolation: the cell is split into six tetrahedra and the
// result is a weighted sum of four corners. This is what Resolve does, and it
// keeps the neutral axis exact, unlike trilinear.
void lutSample(const Lut3D& lut, const float in[3], float out[3])
{
    const int N = lut.size;
    const float* D = lut.data.data();
    float p[3];
    for (int c = 0; c < 3; ++c) {
        const float t = (in[c] - lut.domainMin[c]) / (lut.domainMax[c] - lut.domainMin[c]);
        p[c] = std::fmin(std::fmax(t, 0.0f), 1.0f) * (float)(N - 1);
    }
    int i0[3];
    float f[3];
    for (int c = 0; c < 3; ++c) {
        int k = (int)p[c];
        if (k > N - 2) k = N - 2;
        if (k < 0) k = 0;
        i0[c] = k;
        f[c] = p[c] - (float)k;
    }
    const ptrdiff_t sR = 3, sG = (ptrdiff_t)N * 3, sB = (ptrdiff_t)N * N * 3;
    const ptrdiff_t base = i0[0] * sR + i0[1] * sG + i0[2] * sB;
    const float fr = f[0], fg = f[1], fb = f[2];

    // c000 and c111 are always two of the four corners.
    const float* c000 = D + base;
    const float* c111 = D + base + sR + sG + sB;
    const float *cA, *cB;
    float wA, wB, w000, w111;
    if (fr > fg) {
        if (fg > fb) {        // r > g > b
            cA = D + base + sR;        wA = fr - fg;
            cB = D + base + sR + sG;   wB = fg - fb;
            w000 = 1.0f - fr; w111 = fb;
        } else if (fr > fb) { // r > b >= g
            cA = D + base + sR;        wA = fr - fb;
            cB = D + base + sR + sB;   wB = fb - fg;
            w000 = 1.0f - fr; w111 = fg;
        } else {              // b >= r > g
            cA = D + base + sB;        wA = fb - fr;
            cB = D + base + sR + sB;   wB = fr - fg;
            w000 = 1.0f - fb; w111 = fg;
        }
    } else {
        if (fb > fg) {        // b > g >= r
            cA = D + base + sB;        wA = fb - fg;
            cB = D + base + sG + sB;   wB = fg - fr;
            w000 = 1.0f - fb; w111 = fr;
        } else if (fb > fr) { // g >= b > r
            cA = D + base + sG;        wA = fg - fb;
            cB = D + base + sG + sB;   wB = fb - fr;
            w000 = 1.0f - fg; w111 = fr;
        } else {              // g >= r >= b
            cA = D + base + sG;        wA = fg - fr;
            cB = D + base + sR + sG;   wB = fr - fb;
            w000 = 1.0f - fg; w111 = fb;
        }
    }
    for (int c = 0; c < 3; ++c) out[c] = w000 * c000[c] + wA * cA[c] + wB * cB[c] + w111 * c111[c];
}

void lutApplyCPU(const Lut3D& lut, const float* src, ptrdiff_t srcRowFloats, float* dst, ptrdiff_t dstRowFloats,
                 int width, int rowBegin, int rowEnd)
{
    for (int row = rowBegin; row < rowEnd; ++row) {
        const float* s = src + row * srcRowFloats;
        float* d = dst + row * dstRowFloats;
        for (int x = 0; x < width; ++x, s += 4, d += 4) {
            lutSample(lut, s, d);
            d[3] = s[3];
        }
    }
}

void lutApplyCPUThreaded(const Lut3D& lut, const float* src, ptrdiff_t srcRowFloats, float* dst,
                         ptrdiff_t dstRowFloats, int width, int height)
{
    unsigned n = std::max(1u, std::thread::hardware_concurrency());
    n = std::min<unsigned>(n, (unsigned)std::max(1, height));
    if (n == 1) {
        lutApplyCPU(lut, src, srcRowFloats, dst, dstRowFloats, width, 0, height);
        return;
    }
    std::vector<std::thread> pool;
    pool.reserve(n);
    for (unsigned i = 0; i < n; ++i) {
        const int a = (int)((long long)height * i / n), b = (int)((long long)height * (i + 1) / n);
        pool.emplace_back([&, a, b] { lutApplyCPU(lut, src, srcRowFloats, dst, dstRowFloats, width, a, b); });
    }
    for (auto& t : pool) t.join();
}

} // namespace nodeone
