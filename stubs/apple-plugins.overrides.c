// Hand-written entry points for Apple's Unity plug-ins (Apple.Core, Apple.GameKit)
// built for the Mac. Their startup hooks call in even when the game never uses
// Game Center; the rest is generated as "return 0" by asmtool internalize.

// Apple.Core.RuntimeEnvironment: { uint os; int major, minor, patch; }, returned in
// registers, so a generic stub would leave half of it as garbage. Report
// "Unknown 0.0.0": availability checks then treat every Apple API as missing.
typedef struct { uint32_t os; int32_t major, minor, patch; } RecompAppleRuntimeEnvironment;

__attribute__((used)) RecompAppleRuntimeEnvironment AppleCore_GetRuntimeEnvironment(void)
{
    RecompAppleRuntimeEnvironment env = {0, 0, 0, 0};
    return env;
}
