// =============================================================================
//  NODE_DRT — trial build (compiled only with -DNODEDRT_TRIAL=1)
// -----------------------------------------------------------------------------
//  The trial runs for kTrialDays from the first frame it renders on a Mac.
//  After that the kernel's hidden trial_mark switch is set and the picture is
//  dimmed and covered with a "NODE DRT / TRIAL ENDED" watermark.
//
//  The start date is kept in two small files in the user's Library. Each
//  record carries a checksum; a record that fails it, or a clock set back
//  more than a day before the last time the plugin ran, ends the trial.
//
//  This is a convenience lock, not DRM: NODE_DRT is GPLv3 and anyone may
//  build it from source without this flag.
// =============================================================================
#pragma once
#ifdef NODEDRT_TRIAL

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <sys/stat.h>

namespace nodeone {
namespace trial {

static const int64_t kTrialDays = 30;

inline uint64_t mix(int64_t a, int64_t b)
{
    // FNV-1a over both values and a fixed salt.
    uint64_t h = 1469598103934665603ull;
    auto feed = [&](uint64_t v) {
        for (int i = 0; i < 8; ++i) { h ^= (v >> (8 * i)) & 0xff; h *= 1099511628211ull; }
    };
    feed(0x4e4f444544525431ull);   // "NODEDRT1"
    feed((uint64_t)a);
    feed((uint64_t)b);
    feed(0x7472696c6d61726bull);
    return h;
}

inline std::string home()
{
    const char* h = std::getenv("HOME");
    return h ? std::string(h) : std::string();
}

inline std::string pathA() { return home() + "/Library/Application Support/NodeDRT/.trial"; }
inline std::string pathB() { return home() + "/Library/Preferences/.com.nodeone.ofx.drt.t"; }

// 1 = valid record, 0 = no file, -1 = file present but tampered.
inline int readRec(const std::string& p, int64_t& start, int64_t& last)
{
    FILE* f = std::fopen(p.c_str(), "r");
    if (!f) return 0;
    long long s = 0, l = 0;
    unsigned long long c = 0;
    const int n = std::fscanf(f, "NDRT1 %lld %lld %llx", &s, &l, &c);
    std::fclose(f);
    if (n != 3 || mix(s, l) != (uint64_t)c || s <= 0 || l < s) return -1;
    start = s; last = l;
    return 1;
}

inline void writeRec(const std::string& p, int64_t start, int64_t last)
{
    FILE* f = std::fopen(p.c_str(), "w");
    if (!f) return;
    std::fprintf(f, "NDRT1 %lld %lld %llx\n", (long long)start, (long long)last,
                 (unsigned long long)mix(start, last));
    std::fclose(f);
}

inline int64_t nowSeconds()
{
    using namespace std::chrono;
    return duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
}

// Reads and updates the record. Returns true once the trial is over.
inline bool evaluate()
{
    const std::string h = home();
    if (h.empty()) return false;
    ::mkdir((h + "/Library").c_str(), 0700);
    ::mkdir((h + "/Library/Application Support").c_str(), 0700);
    ::mkdir((h + "/Library/Application Support/NodeDRT").c_str(), 0755);
    ::mkdir((h + "/Library/Preferences").c_str(), 0700);

    const int64_t now = nowSeconds();
    int64_t sA = 0, lA = 0, sB = 0, lB = 0;
    const int a = readRec(pathA(), sA, lA);
    const int b = readRec(pathB(), sB, lB);
    if (a < 0 || b < 0) return true;

    int64_t start = now, last = now;
    if (a > 0) { start = sA; last = lA; }
    if (b > 0) {
        if (a == 0 || sB < start) start = sB;
        if (a == 0 || lB > last)  last  = lB;
    }
    if (now + 86400 < last) return true;           // clock set back
    if (now > last) last = now;
    writeRec(pathA(), start, last);
    writeRec(pathB(), start, last);
    return now - start > kTrialDays * 86400;
}

// Cheap enough to call on every render: the files are read at most once a
// minute, and the verdict is cached in between.
inline bool expired()
{
    static std::mutex m;
    static int64_t nextCheck = 0;
    static bool over = false;
    std::lock_guard<std::mutex> lock(m);
    const int64_t now = nowSeconds();
    if (now >= nextCheck) {
        over = over || evaluate();
        nextCheck = now + 60;
    }
    return over;
}

} // namespace trial
} // namespace nodeone

#endif // NODEDRT_TRIAL
