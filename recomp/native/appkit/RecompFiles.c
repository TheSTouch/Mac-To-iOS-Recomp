// Case-insensitive file lookups for a game written for macOS's default volume
// format, where "libAPEXFramework.dylib" opens libApexFramework.dylib. iOS
// volumes are case-sensitive. The game's path calls are bound here (see
// INTERCEPT in unreal_ios.py); when one fails with ENOENT/ENOTDIR, the path is
// resolved one component at a time ignoring case and the call is retried.
// Calls that create something resolve only the existing parent folders.
//
// This library defines the same names, so calling open() here would call
// itself: the real functions come from RecompRealSym.
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utime.h>

// The system's definition of a function this library also defines (mine).
// Libraries load in dependency order, so libSystem comes before this one.
void *RecompRealSym(const char *name, void *mine) {
    void *p = dlsym(RTLD_DEFAULT, name);
    return p && p != mine ? p : dlsym(RTLD_NEXT, name);
}

#define REAL(name) static __typeof__(&name) real_##name; \
    if (!real_##name) real_##name = (__typeof__(&name))RecompRealSym(#name, (void *)name)

static bool Missing(void) { return errno == ENOENT || errno == ENOTDIR; }

// Writes the case-corrected path into out; false when no such path exists.
// With keepLast, the last component is kept as given (it is being created).
static bool Resolve(const char *path, char *out, size_t n, bool keepLast) {
    REAL(lstat);
    REAL(opendir);
    if (!path || !*path || path[0] == '@') return false;
    char work[PATH_MAX];
    if (path[0] == '/') {
        snprintf(work, sizeof work, "%s", path);
    } else {
        char cwd[PATH_MAX];
        if (!getcwd(cwd, sizeof cwd)) return false;
        snprintf(work, sizeof work, "%s/%s", cwd, path);
    }
    char cur[PATH_MAX] = "";
    size_t len = 0;
    char *save = NULL;
    char *comp = strtok_r(work, "/", &save);
    bool changed = false;
    while (comp) {
        char *next = strtok_r(NULL, "/", &save);
        if (!strcmp(comp, ".")) { comp = next; continue; }
        if (!strcmp(comp, "..")) {
            char *slash = strrchr(cur, '/');
            if (slash) { *slash = 0; len = slash - cur; }
            comp = next;
            continue;
        }
        char cand[PATH_MAX];
        snprintf(cand, sizeof cand, "%s/%s", cur, comp);
        struct stat st;
        if (real_lstat(cand, &st) != 0 && !(keepLast && !next)) {
            DIR *d = real_opendir(len ? cur : "/");
            const char *match = NULL;
            struct dirent *e;
            if (d) {
                while ((e = readdir(d)))
                    if (!strcasecmp(e->d_name, comp)) { match = e->d_name; break; }
            }
            if (!match) { if (d) closedir(d); return false; }
            snprintf(cand, sizeof cand, "%s/%s", cur, match);
            closedir(d);
            changed = true;
        }
        snprintf(cur, sizeof cur, "%s", cand);
        len = strlen(cur);
        comp = next;
    }
    if (!changed) return false;
    snprintf(out, n, "%s", cur);
    return true;
}

// After a failed call: retry once with the case-corrected path, if there is one.
#define RETRY(call_expr, fail_cond, keep) \
    do { \
        char fixed[PATH_MAX]; \
        if ((fail_cond) && Missing() && Resolve(path, fixed, sizeof fixed, keep)) { path = fixed; return call_expr; } \
    } while (0)

int open(const char *path, int flags, ...) {
    REAL(open);
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    int fd = real_open(path, flags, mode);
    RETRY(real_open(path, flags, mode), fd < 0, (flags & O_CREAT) != 0);
    return fd;
}

FILE *fopen(const char *restrict path, const char *restrict mode) {
    REAL(fopen);
    FILE *f = real_fopen(path, mode);
    RETRY(real_fopen(path, mode), !f, mode[0] != 'r');
    return f;
}

int stat(const char *restrict path, struct stat *restrict st) {
    REAL(stat);
    int r = real_stat(path, st);
    RETRY(real_stat(path, st), r != 0, false);
    return r;
}

int statfs(const char *path, struct statfs *st) {
    REAL(statfs);
    int r = real_statfs(path, st);
    RETRY(real_statfs(path, st), r != 0, false);
    return r;
}

int access(const char *path, int mode) {
    REAL(access);
    int r = real_access(path, mode);
    RETRY(real_access(path, mode), r != 0, false);
    return r;
}

DIR *opendir(const char *path) {
    REAL(opendir);
    DIR *d = real_opendir(path);
    RETRY(real_opendir(path), !d, false);
    return d;
}

int chdir(const char *path) {
    REAL(chdir);
    int r = real_chdir(path);
    RETRY(real_chdir(path), r != 0, false);
    return r;
}

ssize_t readlink(const char *restrict path, char *restrict buf, size_t n) {
    REAL(readlink);
    ssize_t r = real_readlink(path, buf, n);
    RETRY(real_readlink(path, buf, n), r < 0, false);
    return r;
}

int chmod(const char *path, mode_t m) {
    REAL(chmod);
    int r = real_chmod(path, m);
    RETRY(real_chmod(path, m), r != 0, false);
    return r;
}

int utime(const char *path, const struct utimbuf *t) {
    REAL(utime);
    int r = real_utime(path, t);
    RETRY(real_utime(path, t), r != 0, false);
    return r;
}

int unlink(const char *path) {
    REAL(unlink);
    int r = real_unlink(path);
    RETRY(real_unlink(path), r != 0, false);
    return r;
}

int rmdir(const char *path) {
    REAL(rmdir);
    int r = real_rmdir(path);
    RETRY(real_rmdir(path), r != 0, false);
    return r;
}

int mkdir(const char *path, mode_t m) {
    REAL(mkdir);
    int r = real_mkdir(path, m);
    RETRY(real_mkdir(path, m), r != 0, true);
    return r;
}

int rename(const char *from, const char *to) {
    REAL(rename);
    int r = real_rename(from, to);
    if (r != 0 && Missing()) {
        char f[PATH_MAX], t[PATH_MAX];
        const char *ff = Resolve(from, f, sizeof f, false) ? f : from;
        const char *tt = Resolve(to, t, sizeof t, true) ? t : to;
        if (ff != from || tt != to) return real_rename(ff, tt);
    }
    return r;
}

void *dlopen(const char *path, int mode) {
    REAL(dlopen);
    void *h = real_dlopen(path, mode);
    if (!h && path && strchr(path, '/')) {
        char fixed[PATH_MAX];
        struct stat st;
        REAL(stat);
        if (real_stat(path, &st) != 0 && Resolve(path, fixed, sizeof fixed, false)) h = real_dlopen(fixed, mode);
    }
    return h;
}
