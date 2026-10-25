// Hand-written PlayFab Party entry points: there is no Party library for this
// iOS build, so initialisation fails and the game stays offline (no crossplay).
// The rest of the Party API is generated as "return 0" by asmtool internalize;
// nothing calls it once initialisation has failed.

// Any non-zero PartyError is a failure; 1 is not the special "already
// initialised" code (4101) the managed wrapper checks for.
#define RECOMP_PARTY_UNAVAILABLE 1

__attribute__((used)) uint32_t PartyInitialize(const uint8_t *titleId, void **handle)
{
    (void)titleId;
    if (handle) *handle = NULL;
    return RECOMP_PARTY_UNAVAILABLE;
}

__attribute__((used)) uint32_t PartyXblInitialize(void *partyHandle, const uint8_t *titleId, void **handle)
{
    (void)partyHandle; (void)titleId;
    if (handle) *handle = NULL;
    return RECOMP_PARTY_UNAVAILABLE;
}

// Error text for logs: the managed side reads it as a UTF-8 C string.
__attribute__((used)) uint32_t PartyGetErrorMessage(uint32_t error, const char **message)
{
    (void)error;
    if (message) *message = "PlayFab Party is not available on iOS";
    return 0;
}

__attribute__((used)) uint32_t PartyXblGetErrorMessage(uint32_t error, const char **message)
{
    return PartyGetErrorMessage(error, message);
}
