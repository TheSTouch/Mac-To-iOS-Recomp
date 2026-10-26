// The bottom tool bar's hover tooltips removed with the game's own HUD too (the Mobile UI's
// MobileHud removes them as it moves the bar's buttons): a finger that starts on the world and
// slides over the bar hovered its buttons and left their tooltips up.
using Timberborn.SingletonSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.TheSTouchscreen
{
    public class BarTooltips : IPostLoadableSingleton
    {
        public void PostLoad()
        {
            if (TouchLayout.On) return;
            foreach (var doc in Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
            {
                var bar = doc.rootVisualElement?.Q("GameUI")?.Q("Bottom-bar");
                if (bar == null) continue;
                MobileHud.RemoveTooltips(bar);
                Debug.Log("[TheSTouchscreen] the tool bar's hover tooltips removed");
                return;
            }
        }
    }
}
