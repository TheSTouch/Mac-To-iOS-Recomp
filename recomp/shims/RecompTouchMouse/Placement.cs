// Aim, then place: desktop building games show a ghost of the building under the mouse,
// let the player rotate it, and place it on the click. A touch is a click the moment it
// lifts, so there is no time to rotate. While a game mod says a building is being placed
// (Active), a touch on the world only moves the mouse: the ghost follows and stays where
// the finger lifts, and the mod's Place button clicks there (see TouchMouse). Touches on
// the game's UI click as usual, and the mouse then goes back to the aimed spot (outside
// placing too: to the last spot touched on the map, so the game sees the mouse leave its
// buttons instead of hovering them). With Rows on, touches act directly again, so a drag draws
// a row (paths, walls) and places it when the finger lifts.
//
// The game side lives in a mod built into the port (Timberborn: recomp/builtin_mods/
// timberborn/TheSTouchscreen), which knows when its placement tools are active and adds the
// buttons to the game's own placement panel.
using UnityEngine;
using UnityEngine.UIElements;
#if RECOMP_UGUI
using UnityEngine.EventSystems;
#endif

namespace Recomp
{
    public static class Placement
    {
        static bool _active;

        /// A building is being placed: touches on the world aim instead of clicking.
        public static bool Active
        {
            get => _active;
            set
            {
                if (value == _active) return;
                _active = value;
                Rows = false;
                TouchMouse.ResetAim();
                Debug.Log("[recomp] placement mode " + (value ? "on" : "off"));
            }
        }

        /// Touches act directly while placing: a drag draws a row and places it on lift.
        public static bool Rows { get; set; }

        /// Clicks where the player last aimed; false when nothing was aimed at yet.
        public static bool Place() => TouchMouse.PlaceAtAim();

        /// Whether the game's UI is under the mouse, as the game itself asks before placing.
        internal static bool MouseOverUI(Vector2 screen)
        {
#if RECOMP_UGUI
            var es = EventSystem.current;
            if (es != null) return es.IsPointerOverGameObject();
#endif
            // No uGUI EventSystem: pick the UI Toolkit panels at the mouse position.
            foreach (var doc in Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
            {
                var panel = doc.rootVisualElement?.panel;
                if (panel == null) continue;
                var p = RuntimePanelUtils.ScreenToPanel(panel, new Vector2(screen.x, Screen.height - screen.y));
                if (panel.Pick(p) != null) return true;
            }
            return false;
        }

        /// Whether the game's UI is at a screen position (Input System pixels, origin bottom-left),
        /// wherever the mouse is: MouseOverUI asks the EventSystem, which answers for the mouse.
        public static bool UiAt(Vector2 screen)
        {
#if RECOMP_UGUI
            var es = EventSystem.current;
            if (es != null)
            {
                Hits.Clear();
                es.RaycastAll(new PointerEventData(es) { position = screen }, Hits);
                if (Hits.Count > 0) return true;
            }
#endif
            foreach (var doc in Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
            {
                var panel = doc.rootVisualElement?.panel;
                if (panel == null) continue;
                var p = RuntimePanelUtils.ScreenToPanel(panel, new Vector2(screen.x, Screen.height - screen.y));
                if (panel.Pick(p) != null) return true;
            }
            return false;
        }

#if RECOMP_UGUI
        static readonly System.Collections.Generic.List<RaycastResult> Hits = new System.Collections.Generic.List<RaycastResult>();
#endif
    }
}
