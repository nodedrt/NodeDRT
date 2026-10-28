// NODE_ONE OFX — compiles each generated Metal kernel exactly as the plugin
// does at runtime (fast-math off) and prints the compiler's diagnostics.
// Usage: build/metal_check gen/*.metal
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>

int main(int argc, const char** argv)
{
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "metal_check: no Metal device\n"); return 2; }
        printf("GPU: %s\n", dev.name.UTF8String);
        int failed = 0;
        for (int i = 1; i < argc; ++i) {
            NSString* path = [NSString stringWithUTF8String:argv[i]];
            NSString* src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!src) { printf("  %-28s cannot read\n", argv[i]); ++failed; continue; }
            MTLCompileOptions* o = [MTLCompileOptions new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            o.fastMathEnabled = NO;
#pragma clang diagnostic pop
            NSError* err = nil;
            NSDate* t0 = [NSDate date];
            id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&err];
            double s = -[t0 timeIntervalSinceNow];
            id<MTLComputePipelineState> pso = nil;
            if (lib) {
                // Every kernel of the library must build a pipeline: the DCTL
                // and LUT sources have one (node_one_main), the texture stage
                // has several.
                NSArray<NSString*>* names = lib.functionNames;
                for (NSString* name in names) {
                    id<MTLFunction> fn = [lib newFunctionWithName:name];
                    if (fn.functionType != MTLFunctionTypeKernel) continue;
                    NSError* perr = nil;
                    pso = [dev newComputePipelineStateWithFunction:fn error:&perr];
                    if (!pso) { if (perr) err = perr; break; }
                }
            }
            if (pso) {
                printf("  %-28s OK   %.2fs  (threads/group %lu)\n", argv[i], s, (unsigned long)pso.maxTotalThreadsPerThreadgroup);
            } else {
                printf("  %-28s FAIL %.2fs\n", argv[i], s);
                ++failed;
            }
            if (err) printf("%s\n", err.localizedDescription.UTF8String);
        }
        return failed ? 1 : 0;
    }
}
