// On-screen keys, stacked in the bottom-left corner: Esc at the bottom (games skip videos,
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
    static class KeyButtons
    {
        const float CheckSeconds = 0.5f;

        const int SortingOrder = 30000;

        // Points (an iPad's 834-point-high screen): size, margin from the corner, gap between keys.
        const float Width = 72, Height = 44, Margin = 16, Gap = 8;

        [Serializable]
        class TouchKey { public string label; public string[] keys; }

        [Serializable]
        class Config { public TouchKey[] touchKeys; }

        class KeyButton
        {
            public string Label;
            public Key[] Keys;
            public Button Button;
            public RectTransform CanvasButton;
        }

        static readonly List<KeyButton> Buttons = new List<KeyButton>();
        static Keyboard _keyboard;
        static UIDocument _overlay;
        static GameObject _canvas;          // uGUI stand-in while there is no UI Toolkit theme
        static float _nextCheck;
        static KeyButton _pressed;
        static int _pressFrames;   // 2: press this update, 1: release this update

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

        public static void Press(int index)
        {
            var b = Buttons[index];
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
        }

        static float Bottom(int index) => Margin + index * (Height + Gap);

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
            // Sized like the UI Toolkit buttons on an iPad.
            var unit = Screen.height / 834f;
            for (int i = 0; i < Buttons.Count; i++)
            {
                var bg = new GameObject("recomp-key-" + Buttons[i].Label, typeof(RectTransform));
                bg.transform.SetParent(_canvas.transform, false);
                var rect = (RectTransform)bg.transform;
                rect.anchorMin = rect.anchorMax = rect.pivot = Vector2.zero;
                rect.anchoredPosition = new Vector2(Margin, Bottom(i)) * unit;
                rect.sizeDelta = new Vector2(Width, Height) * unit;
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
                var text = label.AddComponent<Text>();
                text.font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
                text.text = Buttons[i].Label;
                text.fontSize = Mathf.RoundToInt(18 * unit);
                text.alignment = TextAnchor.MiddleCenter;
                text.color = new Color(1f, 1f, 1f, 0.75f);
                text.raycastTarget = false;
            }
            Debug.Log("[recomp] key buttons added (uGUI overlay): " + Labels());
        }

        static Button Create(string label, int index)
        {
            var b = new Button { text = label, name = "recomp-key-" + label, pickingMode = PickingMode.Ignore };
            var s = b.style;
            s.position = Position.Absolute;
            s.bottom = Bottom(index);  // bottom left: clear of the menus games put along the top
            s.left = Margin;
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
