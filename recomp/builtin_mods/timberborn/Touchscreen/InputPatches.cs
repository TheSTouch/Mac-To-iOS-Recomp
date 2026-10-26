// Harmony patches on the game's input, woven into it at port time (asmtool harmony; see
// recomp/shims/RecompHarmony). They take effect once the game has loaded this mod, and
// change nothing until WorldInput has claimed the input (the game scene): the game then
// reads the pointer, its mouse buttons and whether the pointer is over its UI from
// WorldInput. Everything in the game that reads the mouse goes through these members
// (MouseController and InputService, which asks KeyBindingRegistry for its mouse keys).
using HarmonyLib;
using Timberborn.InputSystem;
using Timberborn.KeyBindingSystem;
using UnityEngine;

namespace Recomp.Touchscreen
{
    [HarmonyPatch(typeof(MouseController), nameof(MouseController.Position), MethodType.Getter)]
    static class MousePositionPatch
    {
        static bool _logged;

        static void Postfix(ref Vector3 __result)
        {
            if (!_logged)
            {
                _logged = true;
                Debug.Log("[Touchscreen] input patch live");
            }
            if (WorldInput.Active) __result = WorldInput.Current.Pointer;
        }
    }

    // The mouse's movement turns the camera while the rotate button is held: never, on touch
    // (CameraService is driven directly).
    [HarmonyPatch(typeof(MouseController), nameof(MouseController.XYAxes), MethodType.Getter)]
    static class MouseAxesPatch
    {
        static void Postfix(ref Vector2 __result)
        {
            if (WorldInput.Active) __result = Vector2.zero;
        }
    }

    [HarmonyPatch(typeof(InputService), nameof(InputService.MouseOverUI), MethodType.Getter)]
    static class MouseOverUIPatch
    {
        static void Postfix(ref bool __result)
        {
            if (WorldInput.Active) __result = WorldInput.Current.MouseOverUI;
        }
    }

    [HarmonyPatch(typeof(KeyBindingRegistry), nameof(KeyBindingRegistry.IsDown))]
    static class KeyDownPatch
    {
        static bool Prefix(string id, ref bool __result) => KeyPatch.Answer(id, KeyQuery.Down, ref __result);
    }

    [HarmonyPatch(typeof(KeyBindingRegistry), nameof(KeyBindingRegistry.IsHeld))]
    static class KeyHeldPatch
    {
        static bool Prefix(string id, ref bool __result) => KeyPatch.Answer(id, KeyQuery.Held, ref __result);
    }

    [HarmonyPatch(typeof(KeyBindingRegistry), nameof(KeyBindingRegistry.IsLongHeld))]
    static class KeyLongHeldPatch
    {
        static bool Prefix(string id, ref bool __result) => KeyPatch.Answer(id, KeyQuery.LongHeld, ref __result);
    }

    [HarmonyPatch(typeof(KeyBindingRegistry), nameof(KeyBindingRegistry.IsUp))]
    static class KeyUpPatch
    {
        static bool Prefix(string id, ref bool __result) => KeyPatch.Answer(id, KeyQuery.Up, ref __result);
    }

    [HarmonyPatch(typeof(KeyBindingRegistry), nameof(KeyBindingRegistry.IsUpAfterShortHeld))]
    static class KeyUpAfterShortHeldPatch
    {
        static bool Prefix(string id, ref bool __result) => KeyPatch.Answer(id, KeyQuery.UpAfterShortHeld, ref __result);
    }

    static class KeyPatch
    {
        static bool _logged;

        // False (skip the game's binding) for the mouse keys while WorldInput has the input.
        internal static bool Answer(string id, KeyQuery query, ref bool result)
        {
            if (!WorldInput.Active) return true;
            var state = WorldInput.Current.Key(id, query);
            if (state == null) return true;
            if (!_logged)
            {
                _logged = true;
                Debug.Log("[Touchscreen] the game's mouse keys come from touches (first asked: " + id + " " + query + ")");
            }
            result = state.Value;
            return false;
        }
    }
}
