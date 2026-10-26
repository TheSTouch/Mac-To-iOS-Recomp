// On-screen keys, stacked in the bottom-left corner (bottom-right for a profile whose
// "touch_keys_corner" is "right", recomp.json "touchKeysCorner"): Esc at the bottom (games skip videos,
// close panels or open their menu with Escape), then the game profile's "touch_keys" above
// it, each a label and the keys it holds down together (recomp.json "touchKeys"), e.g. a
// "Dev" key for a game's developer mode shortcut. The keys are pressed on the keyboard
// device the game's own bindings resolve to: games often look a control up once by path
// (first match wins), so pressing them on an extra keyboard would go unnoticed.
//
// They live in their own UI Toolkit panel sorted above everything the game draws,
// styled with the game's own theme (needed for text to render). UIDocument is an
// engine component the game already uses, so it can be added at runtime; a
// MonoBehaviour of ours could not (the game's data has no script entry for it).
// Games built on uGUI alone (Valheim) have no theme to borrow: they get the same
// buttons as an overlay Canvas with Images and Texts, replaced by the UI Toolkit
// ones if a theme turns up later.
// On a phone the keys are sized in layout points and kept inside the safe area (see Layout).
// With "touch_keys_corner" "island", a phone held sideways puts them in the strip the safe area
// leaves beside the Dynamic Island, square, just under the island, on whichever side it is;
// elsewhere (upright, iPad) they go in the bottom-right corner.
// A game mod can add a key of its own (AddAction): drawn and hit-tested like the others, it
// calls the mod instead of pressing keys, shows only while the mod says so, and beside the
// island it goes above the island.
// Held upright, in a game with the touch gamepad, the stack starts just above the gamepad's
// control zone instead, at the left edge: clear of the move stick, and (in Valheim) far above
// the health and food bars, which stay in the bottom-left corner.
// The panel only draws: TouchMouse hit-tests touches against the buttons and
// calls Press, so the keys do not depend on the game routing UI events to a
// panel it does not know, and a tap on a button never becomes a mouse click.
using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using UnityEngine.UIElements;
using Image = UnityEngine.UI.Image;
using Text = UnityEngine.UI.Text;

namespace Recomp
{
    public static class KeyButtons
    {
        const float CheckSeconds = 0.5f;

        const int SortingOrder = 30000;

        // Layout points (an iPad's 834-point-high screen, see Layout): size, margin from the corner, gap between keys.
        const float Width = 72, Height = 44, Margin = 16, Gap = 8;

        [Serializable]
        class TouchKey { public string label; public string[] keys; }

        [Serializable]
        class Config { public TouchKey[] touchKeys; public string touchKeysCorner; }

        class KeyButton
        {
            public string Label;
            public Key[] Keys;
            public Button Button;
            public RectTransform CanvasButton;
            public Text CanvasText;
            public Action Action;      // a game mod's key (AddAction): called instead of pressing Keys
            public Func<bool> Visible;  // shown while true (null: always)
        }

        static bool Shown(KeyButton b) => b.Visible == null || b.Visible();

        static readonly List<KeyButton> Buttons = new List<KeyButton>();
        static Keyboard _keyboard;
        static UIDocument _overlay;
        static GameObject _canvas;          // uGUI stand-in while there is no UI Toolkit theme
        static float _nextCheck;
        static Rect _laidOut;      // the Layout.Area the buttons were last laid out for (phones, and the uGUI overlay)
        static KeyButton _pressed;
        static int _pressFrames;   // 2: press this update, 1: release this update
        static bool _right;        // in the bottom-right corner instead of the bottom-left
        static bool _island;       // beside the Dynamic Island on a phone held sideways
        static ScreenOrientation _laidOutOrientation;

        public static void Install()
        {
            // Games read Keyboard.current unconditionally; give them one if the device has none,
            // named like a desktop keyboard so "/Keyboard/..." binding paths find it.
            if (Keyboard.current == null)
                InputSystem.AddDevice<Keyboard>("Keyboard");
            Buttons.Add(new KeyButton { Label = "Esc", Keys = new[] { Key.Escape } });
            try
            {
                var path = Path.Combine(Application.streamingAssetsPath, "recomp.json");
                var config = File.Exists(path) ? JsonUtility.FromJson<Config>(File.ReadAllText(path)) : null;
                _island = config?.touchKeysCorner == "island";
                _right = config?.touchKeysCorner == "right" || _island;
                foreach (var k in config?.touchKeys ?? new TouchKey[0])
                {
                    var keys = new List<Key>();
                    foreach (var name in k.keys ?? new string[0])
                    {
                        if (Enum.TryParse(name, true, out Key key) && key != Key.None) keys.Add(key);
                        else Debug.Log("[recomp] touch key " + k.label + ": unknown key " + name);
                    }
                    if (keys.Count > 0) Buttons.Add(new KeyButton { Label = k.label, Keys = keys.ToArray() });
                }
            }
            catch (Exception e)
            {
                Debug.Log("[recomp] touch keys: cannot read recomp.json: " + e.Message);
            }
        }

        /// A key of a game mod's (label also names it: "recomp-key-" + label), calling onPress when
        /// tapped and shown while visible() is true. Beside the Dynamic Island it goes above the
        /// island. Adding a label again replaces its action and visibility.
        public static void AddAction(string label, Action onPress, Func<bool> visible)
        {
            foreach (var existing in Buttons)
                if (existing.Label == label)
                {
                    existing.Action = onPress;
                    existing.Visible = visible;
                    return;
                }
            var b = new KeyButton { Label = label, Keys = new Key[0], Action = onPress, Visible = visible };
            Buttons.Add(b);
            if (_overlay != null)
            {
                b.Button = Create(label, Buttons.Count - 1);
                _overlay.rootVisualElement.Add(b.Button);
            }
            else if (_canvas != null)
            {
                UnityEngine.Object.Destroy(_canvas);
                _canvas = null;
                CreateCanvas();
            }
            _laidOut = default;
            Debug.Log("[recomp] key button added by a game mod: " + label);
        }

        public static void Press(int index)
        {
            var b = Buttons[index];
            if (b.Action != null)
            {
                Debug.Log("[recomp] " + b.Label + " pressed");
                b.Action();
                return;
            }
            _keyboard = InputSystem.FindControl("/Keyboard/" + Keyboard.current?[b.Keys[b.Keys.Length - 1]].name)?.device as Keyboard ?? Keyboard.current;
            if (_keyboard == null) return;
            _pressed = b;
            _pressFrames = 2;
            Debug.Log("[recomp] " + b.Label + " pressed on " + _keyboard.name);
        }

        /// The button under a touch position (Input System screen pixels, origin bottom-left), or -1.
        public static int At(Vector2 screen)
        {
            const float slop = 4f;  // a little extra reach for fingers, less than half the gap
            for (int i = 0; i < Buttons.Count; i++)
            {
                var b = Buttons[i];
                if (!Shown(b)) continue;
                if (b.CanvasButton != null)
                {
                    var c = new Vector3[4];
                    b.CanvasButton.GetWorldCorners(c);  // overlay canvas: world space is screen pixels
                    if (screen.x >= c[0].x - slop && screen.x <= c[2].x + slop && screen.y >= c[0].y - slop && screen.y <= c[2].y + slop)
                        return i;
                    continue;
                }
                if (b.Button == null || b.Button.panel == null) continue;
                var root = _overlay.rootVisualElement.layout;
                if (root.width <= 0f || root.height <= 0f) continue;
                var r = b.Button.worldBound;
                float sx = Screen.width / root.width, sy = Screen.height / root.height;
                var x = screen.x / sx;
                var y = (Screen.height - screen.y) / sy;
                if (x >= r.xMin - slop && x <= r.xMax + slop && y >= r.yMin - slop && y <= r.yMax + slop)
                    return i;
            }
            return -1;
        }

        /// Called from the Input System's dynamic update.
        public static void Update(float now)
        {
            if (_pressFrames > 0)
            {
                var state = _pressFrames == 2 ? new KeyboardState(_pressed.Keys) : new KeyboardState();
                InputSystem.QueueStateEvent(_keyboard, state);
                _pressFrames--;
            }
            if (now >= _nextCheck)
            {
                _nextCheck = now + CheckSeconds;
                Attach();
            }
            // Every frame: after a rotation the buttons must move (and be hit-tested) at once.
            if ((_canvas != null || _overlay != null) && (Layout.Area != _laidOut || Screen.orientation != _laidOutOrientation)) Relayout();
            foreach (var b in Buttons)
            {
                if (b.Visible == null) continue;
                var shown = b.Visible();
                if (b.Button != null && (b.Button.style.display == DisplayStyle.None) == shown)
                    b.Button.style.display = shown ? DisplayStyle.Flex : DisplayStyle.None;
                if (b.CanvasButton != null && b.CanvasButton.gameObject.activeSelf != shown)
                    b.CanvasButton.gameObject.SetActive(shown);
            }
        }

        static float Bottom(int index) => Margin + index * (Height + Gap);

        // Where the stack starts (screen pixels): the area's bottom, or the control zone's top.
        static float Base(Rect area) => Layout.Portrait && TouchPad.Enabled ? Layout.ZoneTop(area) : area.yMin;

        // Beside the Dynamic Island: a phone held sideways, with a strip outside the safe area. The
        // island is on the left in LandscapeLeft (the phone turned counter-clockwise), else the right.
        static bool BesideIsland(Rect area, out bool left)
        {
            left = Screen.orientation == ScreenOrientation.LandscapeLeft;
            return _island && Layout.Phone && !Layout.Portrait && (left ? area.xMin : Screen.width - area.xMax) > 0f;
        }

        // A key beside the island (screen pixels, origin bottom-left): centred in the strip, the
        // stack hanging just under the island (which is centred on the edge, about a third of the
        // short side long), Esc lowest.
        // Square; a game mod's keys (AddAction) stack upwards above the island, the others downwards.
        static Rect IslandKey(Rect area, bool left, int index, float unit)
        {
            var strip = left ? area.xMin : Screen.width - area.xMax;
            var w = Mathf.Min(Width * unit, strip * 0.78f);  // a clear margin to the screen's edge and the HUD
            var h = w;
            var above = Buttons[index].Action != null;
            int count = 0, at = 0;
            for (int i = 0; i < Buttons.Count; i++)
            {
                if ((Buttons[i].Action != null) != above) continue;
                if (i < index) at++;
                count++;
            }
            float y;
            if (above) y = Screen.height * 0.5f + 0.17f * Screen.height + Gap * unit + at * (h + Gap * unit);
            else
            {
                var top = Screen.height * 0.5f - 0.17f * Screen.height - Gap * unit;
                y = top - (count - at) * h - (count - 1 - at) * Gap * unit;
            }
            var x = (left ? strip / 2f : area.xMax + strip / 2f) - w / 2f;
            return new Rect(x, y, w, h);
        }

        static void Attach()
        {
            if (_overlay != null && Buttons[0].Button != null && Buttons[0].Button.panel != null)
            {
                // Games ask the EventSystem whether the pointer is over UI before placing
                // things or moving the camera; every level of this panel must say no.
                for (var e = _overlay.rootVisualElement; e != null; e = e.parent)
                    e.pickingMode = PickingMode.Ignore;
                return;
            }
            PanelSettings theme = null;
            foreach (var doc in UnityEngine.Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
            {
                if (doc != _overlay && doc.panelSettings != null && doc.panelSettings.themeStyleSheet != null)
                {
                    theme = doc.panelSettings;
                    break;
                }
            }
            if (theme == null)
            {
                // No UI Toolkit UI yet (or ever): draw with uGUI once the game shows a canvas.
                if (_canvas == null && UnityEngine.Object.FindAnyObjectByType<Canvas>() != null) CreateCanvas();
                return;
            }
            if (_canvas != null)
            {
                UnityEngine.Object.Destroy(_canvas);
                _canvas = null;
                foreach (var b in Buttons) b.CanvasButton = null;
            }

            var settings = UnityEngine.Object.Instantiate(theme);
            settings.name = "RecompOverlay";
            settings.sortingOrder = SortingOrder;
            settings.targetTexture = null;  // always on screen, even if the game's panel renders to a texture
            var go = new GameObject("RecompOverlay");
            UnityEngine.Object.DontDestroyOnLoad(go);
            _overlay = go.AddComponent<UIDocument>();
            _overlay.panelSettings = settings;
            _overlay.rootVisualElement.pickingMode = PickingMode.Ignore;
            for (int i = 0; i < Buttons.Count; i++)
            {
                if (Buttons[i].Button == null) Buttons[i].Button = Create(Buttons[i].Label, i);
                _overlay.rootVisualElement.Add(Buttons[i].Button);
            }
            _laidOut = default;  // a phone sizes them once the panel has a layout
            Debug.Log("[recomp] key buttons added (theme from " + theme.name + "): " + Labels());
        }

        static string Labels()
        {
            var labels = new List<string>();
            foreach (var b in Buttons) labels.Add(b.Label);
            return string.Join(", ", labels);
        }

        static void CreateCanvas()
        {
            _canvas = new GameObject("RecompOverlayCanvas");
            UnityEngine.Object.DontDestroyOnLoad(_canvas);
            var canvas = _canvas.AddComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            canvas.sortingOrder = SortingOrder;
            // Sized like the UI Toolkit buttons on an iPad (see Relayout).
            for (int i = 0; i < Buttons.Count; i++)
            {
                var bg = new GameObject("recomp-key-" + Buttons[i].Label, typeof(RectTransform));
                bg.transform.SetParent(_canvas.transform, false);
                var rect = (RectTransform)bg.transform;
                rect.anchorMin = rect.anchorMax = rect.pivot = _right ? Vector2.right : Vector2.zero;
                Buttons[i].CanvasButton = rect;
                var image = bg.AddComponent<Image>();
                image.color = new Color(0f, 0f, 0f, 0.35f);
                image.raycastTarget = false;
                var label = new GameObject("label", typeof(RectTransform));
                label.transform.SetParent(bg.transform, false);
                var lr = (RectTransform)label.transform;
                lr.anchorMin = Vector2.zero;
                lr.anchorMax = Vector2.one;
                lr.offsetMin = lr.offsetMax = Vector2.zero;
                var text = Buttons[i].CanvasText = label.AddComponent<Text>();
                text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
                text.text = Buttons[i].Label;
                text.alignment = TextAnchor.MiddleCenter;
                text.color = new Color(1f, 1f, 1f, 0.75f);
                text.raycastTarget = false;
            }
            Relayout();
            Debug.Log("[recomp] key buttons added (uGUI overlay): " + Labels());
        }

        // Sizes and positions for the current screen. The uGUI overlay is in screen pixels. The UI
        // Toolkit buttons keep the fixed sizes of Create in the game's panel on an iPad; on a phone
        // they get the overlay's sizes, converted to the panel's units.
        static void Relayout()
        {
            var area = Layout.Area;
            var unit = Layout.Unit;
            _laidOutOrientation = Screen.orientation;
            var island = BesideIsland(area, out var islandLeft);
            if (_canvas != null)
            {
                for (int i = 0; i < Buttons.Count; i++)
                {
                    var b = Buttons[i];
                    if (b.CanvasButton == null) continue;
                    if (island)
                    {
                        var r = IslandKey(area, islandLeft, i, unit);
                        b.CanvasButton.anchorMin = b.CanvasButton.anchorMax = b.CanvasButton.pivot = Vector2.zero;
                        b.CanvasButton.anchoredPosition = r.position;
                        b.CanvasButton.sizeDelta = r.size;
                        b.CanvasText.fontSize = Mathf.RoundToInt(18 * unit);
                        continue;
                    }
                    b.CanvasButton.anchorMin = b.CanvasButton.anchorMax = b.CanvasButton.pivot = _right ? Vector2.right : Vector2.zero;
                    b.CanvasButton.anchoredPosition = _right
                        ? new Vector2(area.xMax - Screen.width, Base(area)) + new Vector2(-Margin, Bottom(i)) * unit
                        : new Vector2(area.xMin, Base(area)) + new Vector2(Margin, Bottom(i)) * unit;
                    b.CanvasButton.sizeDelta = new Vector2(Width, Height) * unit;
                    b.CanvasText.fontSize = Mathf.RoundToInt(18 * unit);
                }
                _laidOut = area;
                return;
            }
            if (!Layout.Phone)
            {
                _laidOut = area;
                return;
            }
            var root = _overlay != null ? _overlay.rootVisualElement.layout : default;
            if (!(root.height > 0f) || !(root.width > 0f)) return;  // not laid out yet (0 or NaN): next check
            var k = unit * root.height / Screen.height;          // panel units per layout point
            var left = area.xMin * root.width / Screen.width;
            var right = (Screen.width - area.xMax) * root.width / Screen.width;
            var bottom = Base(area) * root.height / Screen.height;
            for (int i = 0; i < Buttons.Count; i++)
            {
                var b = Buttons[i].Button;
                if (b == null) continue;
                var s = b.style;
                if (island)
                {
                    // Screen pixels to the panel's units.
                    var r = IslandKey(area, islandLeft, i, unit);
                    s.left = r.x * root.width / Screen.width;
                    s.right = StyleKeyword.Null;
                    s.bottom = r.y * root.height / Screen.height;
                    s.width = r.width * root.width / Screen.width;
                    s.height = r.height * root.height / Screen.height;
                }
                else
                {
                    if (_right) { s.right = right + Margin * k; s.left = StyleKeyword.Null; }
                    else { s.left = left + Margin * k; s.right = StyleKeyword.Null; }
                    s.bottom = bottom + Bottom(i) * k;
                    s.width = Width * k;
                    s.height = Height * k;
                }
                s.fontSize = 18 * k;
                s.borderTopLeftRadius = s.borderTopRightRadius = s.borderBottomLeftRadius = s.borderBottomRightRadius = 10 * k;
            }
            _laidOut = area;
            Debug.Log($"[recomp] key buttons laid out for a phone: area {area}, panel {root.width}x{root.height}"
                      + (island ? ", beside the Dynamic Island on the " + (islandLeft ? "left" : "right") : ""));
        }

        static Button Create(string label, int index)
        {
            var b = new Button { text = label, name = "recomp-key-" + label, pickingMode = PickingMode.Ignore };
            var s = b.style;
            s.position = Position.Absolute;
            s.bottom = Bottom(index);  // bottom corner: clear of the menus games put along the top
            if (_right) s.right = Margin;
            else s.left = Margin;
            s.width = Width;
            s.height = Height;
            s.fontSize = 18;
            s.color = Color.white;
            s.backgroundColor = new Color(0f, 0f, 0f, 0.45f);
            s.opacity = 0.75f;
            s.borderTopLeftRadius = s.borderTopRightRadius = s.borderBottomLeftRadius = s.borderBottomRightRadius = 10;
            s.borderTopWidth = s.borderBottomWidth = s.borderLeftWidth = s.borderRightWidth = 1;
            s.borderTopColor = s.borderBottomColor = s.borderLeftColor = s.borderRightColor = new Color(1f, 1f, 1f, 0.5f);
            return b;
        }
    }
}
