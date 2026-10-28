// Saves leave this mod out of their mod list. The game writes every enabled mod into a save's
// metadata (SaveMetadataSaveEntryWriter.GetMods), and its loader warns when a mod in that list
// is not enabled (SaveModsValidator), so a save made on the iPad or iPhone warned on the Mac,
// which has no TheSTouchscreen. The mod changes only input and UI, never what is saved, so the
// save does not need it. The check runs one way only (the save's mods against the enabled
// ones): a Mac save loads here without a warning already.
using System.Linq;
using HarmonyLib;
using Timberborn.SaveMetadataSystem;

namespace Recomp.TheSTouchscreen
{
    // The writer is internal to the game, so it is named, not typeof'd.
    [HarmonyPatch("Timberborn.SaveMetadataSaving.SaveMetadataSaveEntryWriter", "GetMods")]
    static class SaveModsPatch
    {
        const string Id = "TheSTouch.TheSTouchscreen";  // manifest.json

        static void Postfix(ref ModReference[] __result)
        {
            if (__result.Any(m => m.Id == Id)) __result = __result.Where(m => m.Id != Id).ToArray();
        }
    }
}
