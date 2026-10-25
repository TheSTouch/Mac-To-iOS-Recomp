// Hand-written Steamworks entry points for running without a Steam client.
// The rest of steam_api is generated as "return 0" by asmtool internalize.

// ESteamAPIInitResult: 0 is OK, so report k_ESteamAPIInitResult_FailedGeneric
// and hand back an empty error string.
__attribute__((used)) int SteamInternal_SteamAPI_Init(const char *versions, char *errMsg)
{
    (void)versions;
    if (errMsg) errMsg[0] = '\0';
    return 1;
}

// Never ask to be relaunched through Steam.
__attribute__((used)) int SteamAPI_RestartAppIfNecessary(uint32_t appId)
{
    (void)appId;
    return 0;
}

__attribute__((used)) int SteamAPI_Init(void) { return 0; }
__attribute__((used)) int SteamAPI_IsSteamRunning(void) { return 0; }
