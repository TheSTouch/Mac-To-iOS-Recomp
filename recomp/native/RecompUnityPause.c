// Unity ports only (copied with the other top-level files of recomp/native; the Unreal
// shim does not build it): UnityPause, which UnityFramework keeps to itself, under a
// name RecompLicense.m can find with dlsym.
void UnityPause(int pause);

__attribute__((used, visibility("default"))) void RecompUnityPause(int pause) { UnityPause(pause); }
