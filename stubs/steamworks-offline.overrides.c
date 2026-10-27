// Formerly Steamworks as a signed-in user with no network, for games that refuse to run
// without Steam (Valheim's profile selects it). The Steam runtime (recomp/native/RecompSteam)
// now signs in for real and keeps SteamAPI_Init succeeding offline within the license's
// grace period, so this file adds nothing to steamworks.overrides.c; it stays for the
// profiles that name it.
