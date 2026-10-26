// Harmony patches on the game's input, woven into it at port time (asmtool harmony; see
// recomp/shims/RecompHarmony). They take effect once the game has loaded this mod.
using HarmonyLib;
using Timberborn.InputSystem;
using UnityEngine;

namespace Recomp.Touchscreen
{
    [HarmonyPatch(typeof(MouseController), nameof(MouseController.Position), MethodType.Getter)]
    static class MousePositionPatch
    {
        static bool _logged;

        static void Postfix()
        {
            if (_logged) return;
            _logged = true;
            Debug.Log("[Touchscreen] input patch live");
        }
    }
}
