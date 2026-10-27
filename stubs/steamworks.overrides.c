// Steamworks in a port: recomp/native/RecompSteam, the pseudo Steam client every port
// carries, implements SteamAPI_Init, the interfaces and what a game needs from Steam
// (unity_ios.py lists its functions to asmtool, so no stub is generated for them).
// Every other entry point is generated as "return 0" by asmtool internalize.
//
// Hand-written bodies for functions the runtime does not implement and where 0 means the
// wrong thing go here; none are needed at present.
