// The Harmony entry points mods call at start-up. On iOS nothing can be patched at run time:
// the [HarmonyPatch] classes were woven into the game when it was ported (asmtool harmony),
// and they only take effect for mods the game has loaded. PatchAll therefore has nothing
// left to do; Patch with a method picked at run time cannot be honoured, and says so.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

namespace HarmonyLib
{
    public class Harmony
    {
        public static bool DEBUG;

        public string Id { get; private set; }

        public Harmony(string id)
        {
            if (string.IsNullOrEmpty(id)) throw new ArgumentException("id cannot be null or empty");
            Id = id;
        }

        public void PatchAll() { }

        public void PatchAll(Assembly assembly) { }

        public void PatchAllUncategorized() { }

        public void PatchAllUncategorized(Assembly assembly) { }

        public void PatchCategory(string category) { }

        public void PatchCategory(Assembly assembly, string category) { }

        public MethodInfo Patch(MethodBase original, HarmonyMethod prefix = null, HarmonyMethod postfix = null,
                                HarmonyMethod transpiler = null, HarmonyMethod finalizer = null)
        {
            Console.WriteLine($"[recomp] harmony: {Id} patches {original?.DeclaringType}.{original?.Name} at run time, which iOS cannot do; " +
                              "only [HarmonyPatch] classes are applied (woven when the game was ported)");
            return original as MethodInfo;
        }

        public void Unpatch(MethodBase original, HarmonyPatchType type, string harmonyID = "*") { }

        public void Unpatch(MethodBase original, MethodInfo patch) { }

        public void UnpatchAll(string harmonyID = null) { }

        public void UnpatchSelf() { }

        public void UnpatchCategory(string category) { }

        public void UnpatchCategory(Assembly assembly, string category) { }

        public IEnumerable<MethodBase> GetPatchedMethods() => Enumerable.Empty<MethodBase>();

        public static IEnumerable<MethodBase> GetAllPatchedMethods() => Enumerable.Empty<MethodBase>();

        public static bool HasAnyPatches(string harmonyID) => false;

        public static Dictionary<string, Version> VersionInfo(out Version currentVersion)
        {
            currentVersion = typeof(Harmony).Assembly.GetName().Version;
            return new Dictionary<string, Version>();
        }
    }
}
