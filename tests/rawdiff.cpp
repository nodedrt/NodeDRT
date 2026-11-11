// rawdiff a.raw b.raw : max / mean absolute difference between two float dumps,
// and how many values differ at all, plus the worst difference in 10-bit code values.
#include <cmath>
#include <cstdio>
#include <vector>
int main(int argc, char** argv)
{
    if (argc < 3) return 2;
    FILE* fa = fopen(argv[1], "rb"); FILE* fb = fopen(argv[2], "rb");
    if (!fa || !fb) { printf("cannot open\n"); return 2; }
    std::vector<float> a, b; float x;
    while (fread(&x, 4, 1, fa) == 1) a.push_back(x);
    while (fread(&x, 4, 1, fb) == 1) b.push_back(x);
    if (a.size() != b.size()) { printf("size differs\n"); return 1; }
    double mx = 0, sum = 0; size_t nd = 0, nan = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        if (std::isnan(a[i]) != std::isnan(b[i])) { ++nan; continue; }
        if (std::isnan(a[i])) continue;
        const double d = std::fabs((double)a[i] - b[i]);
        if (d > 0) ++nd;
        if (d > mx) mx = d;
        sum += d;
    }
    printf("max %.3g  mean %.3g  differing %zu / %zu  (%.4f%%)  nan-mismatch %zu  worst = %.4f ten-bit codes\n",
           mx, sum / a.size(), nd, a.size(), 100.0 * nd / a.size(), nan, mx * 1023.0);
    return 0;
}
