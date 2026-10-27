// The Touch layout ("Mobile UI"): MobileHud's HUD, and the Development controls modal with its
// bug key (DevControls). Always on on an iPhone. On an iPad it is a choice, off by default (the
// game's own HUD and Development controls), made in the game's settings: a "Mobile UI" toggle
// in Settings › Interface (SettingsTogglePatch), iPad only. The choice is remembered across
// launches (PlayerPrefs "TheSTouchscreen.Enabled"). Turning it on in a game applies at once:
// the layout runs as it does after a save loads. Turning it off applies the next time a save is
// loaded: MobileHud takes the game's HUD apart (moves its panels, writes their styles, removes
// the bar's tooltips), and putting all of that back in a running game is not worth the risk of a
// half-restored HUD. Touch input (WorldInput) is not part of this: it is on everywhere.
using System;
using HarmonyLib;
using Timberborn.CoreUI;
using Timberborn.SingletonSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.TheSTouchscreen
{
    public class TouchLayout : ILoadableSingleton, IUnloadableSingleton
    {
        const string Pref = "TheSTouchscreen.Enabled";

        internal static readonly bool Phone = SystemInfo.deviceModel.StartsWith("iPhone", StringComparison.Ordinal);

        /// On in this game: the choice when the save loaded, or turned on since.
        internal static bool On { get; private set; }

        internal static bool Chosen => Phone || PlayerPrefs.GetInt(Pref, 0) == 1;

        static TouchLayout _current;  // in a game

        readonly MobileHud _mobileHud;
        readonly DevControls _devControls;

        public TouchLayout(MobileHud mobileHud, DevControls devControls)
        {
            _mobileHud = mobileHud;
            _devControls = devControls;
        }

        public void Load()
        {
            On = Chosen;
            _current = this;
            Debug.Log("[TheSTouchscreen] touch layout " + (On ? "on" : "off") + (Phone ? " (iPhone)" : " (iPad: Settings › Interface › Mobile UI)"));
        }

        public void Unload()
        {
            if (_current == this) _current = null;
        }

        /// The settings' toggle: remembered; turning it on in a game applies at once.
        internal static void Choose(bool on)
        {
            PlayerPrefs.SetInt(Pref, on ? 1 : 0);
            PlayerPrefs.Save();
            Debug.Log("[TheSTouchscreen] touch layout chosen " + (on ? "on" : "off"));
            if (!on || On || _current == null) return;
            On = true;
            _current._mobileHud.PostLoad();
            _current._devControls.PostLoad();
            Debug.Log("[TheSTouchscreen] touch layout turned on in the game");
        }
    }

    // The game builds its settings box once per scene (SettingsBox.Load, from
    // Views/Options/SettingsBox.uxml): a Mobile UI toggle goes after Interface's UI scale, styled
    // like the game's own toggles, with a line saying when a change applies, and under it, in a
    // game turned off, "Reload save now" (ReloadSave). iPad only.
    [HarmonyPatch(typeof(VisualElementLoader), nameof(VisualElementLoader.LoadVisualElement), typeof(string))]
    static class SettingsTogglePatch
    {
        static void Postfix(string elementName, VisualElement __result)
        {
            if (elementName != "Options/SettingsBox" || TouchLayout.Phone || __result == null) return;
            var after = __result.Q("UIScaleFactor");
            if (after?.parent == null) return;
            var toggle = new Toggle { text = "Mobile UI", name = "TheSTouchscreenMobileUI", focusable = false };
            toggle.AddToClassList("settings-element");
            toggle.AddToClassList("settings-toggle");
            toggle.AddToClassList("settings-text");
            toggle.SetValueWithoutNotify(TouchLayout.Chosen);
            var reload = ReloadSave.CreateButton();
            toggle.RegisterValueChangedCallback(e =>
            {
                TouchLayout.Choose(e.newValue);
                ReloadSave.Update(reload);
            });
            var note = new Label("Turning it on applies at once; off, the next time a save is loaded.");
            note.AddToClassList("settings-text");
            note.style.fontSize = 13f;
            note.style.opacity = 0.75f;
            note.style.marginBottom = 6f;
            var parent = after.parent;
            parent.Insert(parent.IndexOf(after) + 1, toggle);
            parent.Insert(parent.IndexOf(toggle) + 1, note);
            parent.Insert(parent.IndexOf(note) + 1, reload);
        }
    }
}
