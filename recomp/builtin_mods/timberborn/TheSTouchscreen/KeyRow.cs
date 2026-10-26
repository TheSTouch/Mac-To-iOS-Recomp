// Where the port's keys (Esc, Dev and DevControls' bug key) go on an iPad, measured from the
// game's UI each half second and handed to the shim (Recomp.KeyButtons.PlaceInRow), which draws
// and hit-tests them there. An iPhone keeps them beside the Dynamic Island.
//   Mobile UI off (the game's own HUD): a row at the left edge just above the bottom tool bar,
//     under the alerts (Common/AlertPanel, 120 units up in the bottom-left slot), as tall as the
//     room between them allows, up to 44 pt; at the bottom edge while the bar is hidden. The
//     game's own Development controls (DevPanel, absolute at 60 units up, 258 wide) sit there
//     while developer mode is on: the row starts right of them then.
//   Mobile UI on (TouchLayout): a row at the bottom right, Esc at the right edge, just above
//     what the game's bottom-right slot shows (the FPS counter, the tutorial).
using Timberborn.SingletonSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.TheSTouchscreen
{
    public class KeyRow : IPostLoadableSingleton, IUnloadableSingleton, IUpdatableSingleton
    {
        // Layout points (Recomp.KeyButtons.Unit), and the alerts' height when they cannot be measured.
        const float Size = 44f, MinSize = 32f, Edge = 12f, Clear = 2f, AlertsBottom = 120f;
        const float CheckSeconds = 0.5f;

        VisualElement _gameUI;
        KeyButtons.Row? _row;
        float _nextCheck;

        public void PostLoad()
        {
            if (TouchLayout.Phone) return;
            foreach (var doc in Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
                if ((_gameUI = doc.rootVisualElement?.Q("GameUI")) != null) break;
            if (_gameUI == null) return;
            KeyButtons.PlaceInRow(() => _row);
            Debug.Log("[TheSTouchscreen] keys in a row: above the tool bar, or bottom right with the Mobile UI");
        }

        public void Unload()
        {
            if (_gameUI != null) KeyButtons.PlaceInRow(null);
        }

        public void UpdateSingleton()
        {
            if (_gameUI == null || Time.unscaledTime < _nextCheck) return;
            _nextCheck = Time.unscaledTime + CheckSeconds;
            var root = _gameUI.panel?.visualTree.layout ?? default;
            if (!(root.width > 0f) || !(root.height > 0f)) return;
            // Panel units (origin top-left) to screen pixels (origin bottom-left).
            float sx = Screen.width / root.width, sy = Screen.height / root.height;
            float Up(float y) => (root.height - y) * sy;
            var pt = KeyButtons.Unit;
            if (TouchLayout.On)
            {
                var slot = _gameUI.Q("Bottom-right");
                var top = slot?.worldBound.yMax ?? root.height;
                if (slot != null)
                    foreach (var child in slot.Children())
                        if (Shown(child)) top = Mathf.Min(top, child.worldBound.yMin);
                var right = _gameUI.worldBound.xMax * sx - Edge * pt;
                _row = new KeyButtons.Row { Area = new Rect(0f, Up(top) + Clear * pt, right, Size * pt), FromRight = true };
                return;
            }
            var bar = _gameUI.Q("Bottom-bar")?.Q("MainSection");
            var barTop = bar != null && Shown(bar) ? Up(bar.worldBound.yMin) : 0f;
            var alerts = _gameUI.Q("Alerts");
            var alertsBottom = alerts?.panel != null ? Up(alerts.worldBound.yMax) : AlertsBottom * sy;
            var size = Mathf.Clamp(alertsBottom - barTop - 2f * Clear * sy, MinSize * pt, Size * pt);
            var devPanel = _gameUI.Q("Bottom-left")?.Q("DevPanel");
            var left = devPanel != null && Shown(devPanel) ? devPanel.worldBound.xMax * sx + Edge * pt : Edge * pt;
            _row = new KeyButtons.Row { Area = new Rect(left, barTop + Clear * sy, Screen.width / 2f, size), FromRight = false };
        }

        // Laid out and shown, up to the game's HUD root.
        bool Shown(VisualElement e)
        {
            if (!(e.worldBound.height > 0f)) return false;
            for (; e != null && e != _gameUI; e = e.parent)
                if (e.resolvedStyle.display == DisplayStyle.None || !e.visible) return false;
            return e == _gameUI;
        }
    }
}
