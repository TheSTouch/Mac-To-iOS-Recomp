// The Touch layout: MobileHud's HUD, and the Development controls modal with its bug key
// (DevControls). Always on on an iPhone. On an iPad it is a choice, off by default (the game's
// own HUD and Development controls), turned on and off by a Touch key that only an iPad gets
// (Recomp.KeyButtons.AddAction). The choice is remembered across launches (PlayerPrefs
// "TheSTouchscreen.Enabled") and applies the next time a save is loaded: MobileHud moves the
// game's panels, and undoing that in a running game is risky; the game's message box says so.
// The Touch key shows the choice at once: the game's frame when on, the port's plain key when
// off. Touch input (WorldInput) is not part of this: it is on everywhere.
using System;
using Timberborn.CoreUI;
using Timberborn.SingletonSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.TheSTouchscreen
{
    public class TouchLayout : ILoadableSingleton, IUnloadableSingleton, IUpdatableSingleton
    {
        internal const string KeyLabel = "Touch";
        const string Pref = "TheSTouchscreen.Enabled";
        const float CheckSeconds = 0.5f;

        internal static readonly bool Phone = SystemInfo.deviceModel.StartsWith("iPhone", StringComparison.Ordinal);

        /// On in this game: the choice as it was when the save loaded.
        internal static bool On { get; private set; }

        static bool Chosen => Phone || PlayerPrefs.GetInt(Pref, 0) == 1;

        static bool _inGame;  // read by the key's visibility, which outlives this scene

        readonly DialogBoxShower _dialogBoxShower;
        Button _key;
        bool? _keyFramed;
        float _nextCheck;

        public TouchLayout(DialogBoxShower dialogBoxShower)
        {
            _dialogBoxShower = dialogBoxShower;
        }

        public void Load()
        {
            On = Chosen;
            _inGame = true;
            if (!Phone) KeyButtons.AddAction(KeyLabel, Toggle, () => _inGame);
            Debug.Log("[TheSTouchscreen] touch layout " + (On ? "on" : "off") + (Phone ? " (iPhone)" : " (iPad: the Touch key turns it on or off)"));
        }

        public void Unload() => _inGame = false;

        void Toggle()
        {
            var on = !Chosen;
            PlayerPrefs.SetInt(Pref, on ? 1 : 0);
            PlayerPrefs.Save();
            ShowChoice();
            Debug.Log("[TheSTouchscreen] touch layout chosen " + (on ? "on" : "off") + ", from the next save loaded");
            _dialogBoxShower.Create()
                .SetMessage("Touch layout " + (on ? "on" : "off") + ". It applies the next time a save is loaded.")
                .Show();
        }

        public void UpdateSingleton()
        {
            if (Phone || Time.unscaledTime < _nextCheck) return;
            _nextCheck = Time.unscaledTime + CheckSeconds;
            ShowChoice();
        }

        // The key the shim drew for us, framed while the choice is on.
        void ShowChoice()
        {
            if (_key == null || _key.panel == null)
            {
                _key = null;
                _keyFramed = null;
                foreach (var doc in UnityEngine.Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
                    if (doc.name == "RecompOverlay") _key = doc.rootVisualElement?.Q<Button>("recomp-key-" + KeyLabel);
                if (_key == null) return;
            }
            if (_keyFramed == Chosen) return;
            _keyFramed = Chosen;
            if (Chosen) MobileHud.Frame(_key);
            else Plain(_key);
        }

        // As the shim draws its keys (Recomp.KeyButtons.Create).
        static void Plain(Button b)
        {
            var s = b.style;
            s.backgroundImage = StyleKeyword.Null;
            s.backgroundColor = new Color(0f, 0f, 0f, 0.45f);
            s.borderTopWidth = s.borderBottomWidth = s.borderLeftWidth = s.borderRightWidth = 1f;
            s.borderTopColor = s.borderBottomColor = s.borderLeftColor = s.borderRightColor = new Color(1f, 1f, 1f, 0.5f);
            s.opacity = 0.75f;
            s.color = Color.white;
            s.unityFontStyleAndWeight = FontStyle.Normal;
        }
    }
}
