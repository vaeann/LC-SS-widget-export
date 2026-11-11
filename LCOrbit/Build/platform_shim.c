// Cross-toolchain shim: clang lowers @available(...) to calls of
// __isPlatformVersionAtLeast, which Apple's libclang_rt.ios provides. The
// Linux toolchain has no such static lib, so we link this equivalent that
// reads the real OS version via sysctl — same semantics, device-accurate.
#include <stdbool.h>
#include <stdio.h>
#include <sys/sysctl.h>

bool __isPlatformVersionAtLeast(const char *name, int major, int minor, int patch) {
    (void)name; // the target is fixed at build time (arm64-apple-ios)
    char osver[32] = {0};
    size_t size = sizeof(osver);
    if (sysctlbyname("kern.osproductversion", osver, &size, NULL, 0) != 0) return false;
    int cmaj = 0, cmin = 0, cpat = 0;
    if (sscanf(osver, "%d.%d.%d", &cmaj, &cmin, &cpat) < 1) return false;
    if (cmaj != major) return cmaj > major;
    if (cmin != minor) return cmin > minor;
    return cpat >= patch;
}
