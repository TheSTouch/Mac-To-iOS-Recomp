// Hand-written entry points for Valheim's small Mac helper libraries
// (DiskSpacePlugin, libHasPreciseScrolling, libMacScreenScale).
#include <stdlib.h>
#include <sys/mount.h>

// The game blocks saving when free space is low, so 0 would block every save.
// -1 means "unknown" to the game (treated as unlimited); answer for real instead.
__attribute__((used)) int64_t get_free_space(const char *path)
{
    struct statfs s;
    if (!path || statfs(path, &s) != 0)
        return -1;
    return (int64_t)s.f_bavail * (int64_t)s.f_bsize;
}

// Mouse wheels give coarse steps; the touch shim's two-finger scroll does too.
__attribute__((used)) int hasPreciseScrolling(void) { return 0; }

// A Retina Mac answers 2 and the game renders at point resolution (height / 2)
// instead of the full pixel count. iPad screens are 2x as well, and rendering
// every pixel costs far more frame time than the sharpness is worth.
__attribute__((used)) float GetScreenScaleFactor(void) { return 2.0f; }

// SteamManager reads the app id from SteamAppId (or steam_appid.txt in the
// working directory, which an iOS app does not have) and quits on any other.
__attribute__((constructor)) static void recomp_valheim_app_id(void)
{
    setenv("SteamAppId", "892970", 0);
}
