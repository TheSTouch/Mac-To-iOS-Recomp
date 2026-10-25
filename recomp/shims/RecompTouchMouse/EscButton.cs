// An on-screen Esc key for games that skip videos, close panels or open their
// menu with Escape. The key is pressed on the keyboard device the game's own
// bindings resolve to: games often look a control up once by path (first match
// wins), so pressing it on an extra keyboard would go unnoticed.
//
// It lives in its own UI Toolkit panel sorted above everything the game draws,
// styled with the game's own theme (needed for text to render). UIDocument is an
// engine component the game already uses, so it can be added at runtime; a
// MonoBehaviour of ours could not (the game's data has no script entry for it).
// Games built on uGUI alone (Valheim) have no theme to borrow: they get the same
// button as an overlay Canvas with an Image and a Text, replaced by the UI Toolkit
// one if a theme turns up later.
// The panel only draws: TouchMouse hit-tests touches against the button and
// calls Press, so the key does not depend on the game routing UI events to a
// panel it does not know, and a tap on the button never becomes a mouse click.
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using UnityEngine.UIElements;
using Image = UnityEngine.UI.Image;
using Text = UnityEngine.UI.Text;

namespace Recomp
{
    static class EscButton
    {
        const float CheckSeconds = 0.5f;

        const int SortingOrder = 30000;

        static Keyboard _keyboard;
        static Button _button;
        static UIDocument _overlay;
        static GameObject _canvas;          // uGUI stand-in while there is no UI Toolkit theme
        static RectTransform _canvasButton;
        static float _nextCheck;
        static int _pressFrames;   // 2: press this update, 1: release this update

        public static void Install()
        {
            // Games read Keyboard.current unconditionally; give them one if the device has none,
            // named like a desktop keyboard so "/Keyboard/..." binding paths find it.
            if (Keyboard.current == null)
                InputSystem.AddDevice<Keyboard>("Keyboard");
        }

        public static void Press()
        {
            _keyboard = InputSystem.FindControl("/Keyboard/escape")?.device as Keyboard ?? Keyboard.current;
            if (_keyboard == null) return;
            _pressFrames = 2;
            Debug.Log("[recomp] Esc pressed on " + _keyboard.name);
        }

        /// Whether a touch position (Input System screen pixels, origin bottom-left) is on the button.
        public static bool Contains(Vector2 screen)
        {
            const float slop = 8f;  // a little extra reach for fingers
            if (_canvasButton != null)
            {
                var c = new Vector3[4];
                _canvasButton.GetWorldCorners(c);  // overlay canvas: world space is screen pixels
                return screen.x >= c[0].x - slop && screen.x <= c[2].x + slop && screen.y >= c[0].y - slop && screen.y <= c[2].y + slop;
            }
            if (_button == null || _button.panel == null) return false;
            var root = _overlay.rootVisualElement.layout;
            if (root.width <= 0f || root.height <= 0f) return false;
            var r = _button.worldBound;
            float sx = Screen.width / root.width, sy = Screen.height / root.height;
            var x = screen.x / sx;
            var y = (Screen.height - screen.y) / sy;
            return x >= r.xMin - slop && x <= r.xMax + slop && y >= r.yMin - slop && y <= r.yMax + slop;
        }

        /// Called from the Input System's dynamic update.
        public static void Update(float now)
        {
            if (_pressFrames > 0)
            {
                var state = _pressFrames == 2 ? new KeyboardState(Key.Escape) : new KeyboardState();
                InputSystem.QueueStateEvent(_keyboard, state);
                _pressFrames--;
            }
            if (now >= _nextCheck)
            {
                _nextCheck = now + CheckSeconds;
                Attach();
            }
        }

        static void Attach()
        {
            if (_overlay != null && _button != null && _button.panel != null)
            {
                // Games ask the EventSystem whether the pointer is over UI before placing
                // things or moving the camera; every level of this panel must say no.
                for (var e = _overlay.rootVisualElement; e != null; e = e.parent)
                    e.pickingMode = PickingMode.Ignore;
                return;
            }
            PanelSettings theme = null;
            foreach (var doc in Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
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
                if (_canvas == null && Object.FindAnyObjectByType<Canvas>() != null) CreateCanvas();
                return;
            }
            if (_canvas != null)
            {
                Object.Destroy(_canvas);
                _canvas = null;
                _canvasButton = null;
            }

            var settings = Object.Instantiate(theme);
            settings.name = "RecompOverlay";
            settings.sortingOrder = SortingOrder;
            settings.targetTexture = null;  // always on screen, even if the game's panel renders to a texture
            var go = new GameObject("RecompOverlay");
            Object.DontDestroyOnLoad(go);
            _overlay = go.AddComponent<UIDocument>();
            _overlay.panelSettings = settings;
            _overlay.rootVisualElement.pickingMode = PickingMode.Ignore;
            if (_button == null) _button = Create();
            _overlay.rootVisualElement.Add(_button);
            Debug.Log("[recomp] Esc button added (theme from " + theme.name + ")");
        }

        static void CreateCanvas()
        {
            _canvas = new GameObject("RecompOverlayCanvas");
            Object.DontDestroyOnLoad(_canvas);
            var canvas = _canvas.AddComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            canvas.sortingOrder = SortingOrder;
            // Sized like the UI Toolkit button on an iPad (72 x 44 points, 16 from the corner).
            var unit = Screen.height / 834f;
            var bg = new GameObject("recomp-esc", typeof(RectTransform));
            bg.transform.SetParent(_canvas.transform, false);
            _canvasButton = (RectTransform)bg.transform;
            _canvasButton.anchorMin = _canvasButton.anchorMax = _canvasButton.pivot = Vector2.zero;
            _canvasButton.anchoredPosition = new Vector2(16, 16) * unit;
            _canvasButton.sizeDelta = new Vector2(72, 44) * unit;
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
            text.text = "Esc";
            text.fontSize = Mathf.RoundToInt(18 * unit);
            text.alignment = TextAnchor.MiddleCenter;
            text.color = new Color(1f, 1f, 1f, 0.75f);
            text.raycastTarget = false;
            Debug.Log("[recomp] Esc button added (uGUI overlay)");
        }

        static Button Create()
        {
            var b = new Button { text = "Esc", name = "recomp-esc", pickingMode = PickingMode.Ignore };
            var s = b.style;
            s.position = Position.Absolute;
            s.bottom = 16;  // bottom left: clear of the menus games put along the top
            s.left = 16;
            s.width = 72;
            s.height = 44;
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
