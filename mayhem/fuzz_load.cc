// Writes the fuzzer's bytes to a scratch file named with FF_EXT and opens it with
// LoadSplineFont(), FontForge's front door for every font format it reads. FontForge
// picks the parser from the first bytes of the file and, when they match nothing, from
// the file name's extension; FF_EXT selects which extension-driven reader a target reaches.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

#include "fontforge.h"
#include "splinefont.h"
#include "splineutil.h"
#include "start.h"

#ifndef FF_EXT
#error "compile with -DFF_EXT=\".ext\""
#endif

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
    doinitFontForgeMain();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const char *dir = getenv("TMPDIR");
    if (dir == NULL || *dir == '\0')
        dir = "/tmp";
    char path[4096];
    snprintf(path, sizeof path, "%s/ffXXXXXX%s", dir, FF_EXT);
    int fd = mkstemps(path, (int)strlen(FF_EXT));
    if (fd < 0)
        return 0;
    size_t off = 0;
    while (off < size) {
        ssize_t n = write(fd, data + off, size - off);
        if (n <= 0)
            break;
        off += (size_t)n;
    }
    close(fd);

    SplineFont *sf = LoadSplineFont(path, of_fstypepermitted);
    if (sf != NULL)
        SplineFontFree(sf);
    unlink(path);
    return 0;
}
