// On-screen gamepad for action games, the Unity counterpart of the Unreal
// route's RecompTouchPad.m (same layout and stick feel). Touches drive a
// virtual Input System gamepad that the game reads like a real one.
//
// Shown while the game has locked the cursor (it is in play, not in a mouse
// menu) and no physical controller is connected; otherwise touches stay the
// mouse (TouchMouse). Left half: floating move stick; right half: floating
// camera stick; A/B/X/Y bottom right, shoulders and triggers along the top,
// Menu and View top left. A quick tap that misses the buttons is a left click
// at that spot, so mouse menus stay reachable from the pad.
//
// Opt-in per game: the port's profile sets "touch_gamepad", which inject
// writes to StreamingAssets/recomp.json.
using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using Image = UnityEngine.UI.Image;
using Text = UnityEngine.UI.Text;

namespace Recomp
{
    static class TouchPad
    {
        const float StickTravel = 110f;  // points of drag for full deflection
        const float DeadZone = 0.1f;
        const float TapSeconds = 0.3f;
        const float TapSlop = 12f;       // points
        const int SortingOrder = 29999;  // under the Esc button

        [Serializable]
        class Config { public bool touchGamepad; }

        class PadButton
        {
            public string Name;
            public Vector2 At;       // points: x from the left (>0) or right (<0) edge, y from the bottom (>0) or top (<0) edge
            public float Radius;
            public GamepadButton Input;
            public Image Image;
            public bool Down;
        }

        class Stick
        {
            public float Curve;      // response exponent: higher = finer control near the centre
            public Vector2 Origin, Value;
            public RectTransform Base, Knob;
            public int Touch = -1;
        }

        class Owner
        {
            public PadButton Button;
            public Stick Stick;
            public Vector2 Start;
            public float Time;
            public bool Moved;
        }

        static bool _enabled, _visible;
        static Gamepad _pad;
        static GameObject _canvas;
        static Sprite _circle;
        static readonly Stick Left = new Stick { Curve = 1.3f }, Right = new Stick { Curve = 1.8f };
        static readonly List<PadButton> Buttons = new List<PadButton>();
        static readonly Dictionary<int, Owner> Owners = new Dictionary<int, Owner>();

        static float Unit => Screen.height / 834f;  // iPad points to pixels, as EscButton

        public static void Install()
        {
            try
            {
                var path = Path.Combine(Application.streamingAssetsPath, "recomp.json");
                _enabled = File.Exists(path) && JsonUtility.FromJson<Config>(File.ReadAllText(path)).touchGamepad;
            }
            catch (Exception e)
            {
                Debug.Log("[recomp] touch gamepad: cannot read recomp.json: " + e.Message);
            }
            if (!_enabled) return;
            const float k = 62f;  // face-button spacing
            Add("A", new Vector2(-140, 90), 32, GamepadButton.South);
            Add("B", new Vector2(-140 + k, 90 + k), 32, GamepadButton.East);
            Add("X", new Vector2(-140 - k, 90 + k), 32, GamepadButton.West);
            Add("Y", new Vector2(-140, 90 + 2 * k), 32, GamepadButton.North);
            Add("LB", new Vector2(56, -170), 24, GamepadButton.LeftShoulder);
            Add("LT", new Vector2(56, -110), 24, GamepadButton.LeftTrigger);
            Add("RB", new Vector2(-56, -170), 24, GamepadButton.RightShoulder);
            Add("RT", new Vector2(-56, -110), 24, GamepadButton.RightTrigger);
            Add("Menu", new Vector2(48, -34), 22, GamepadButton.Start);
            Add("View", new Vector2(108, -34), 22, GamepadButton.Select);
            Add("L3", new Vector2(56, 120), 22, GamepadButton.LeftStick);  // above the Esc button
            Add("R3", new Vector2(-260, 50), 22, GamepadButton.RightStick);
            // Named like a pad so "<Gamepad>" bindings find it. It stays idle while hidden:
            // games pick their input mode from the device last used, not from what is connected.
            _pad = InputSystem.AddDevice<Gamepad>("RecompTouchGamepad");
            Debug.Log("[recomp] touch gamepad enabled");
        }

        static void Add(string name, Vector2 at, float radius, GamepadButton input) =>
            Buttons.Add(new PadButton { Name = name, At = at, Radius = radius, Input = input });

        public static bool Visible => _visible;
        public static bool Owns(int touch) => Owners.ContainsKey(touch);

        static Vector2 Place(Vector2 at) =>
            new Vector2(at.x >= 0 ? at.x * Unit : Screen.width + at.x * Unit, at.y >= 0 ? at.y * Unit : Screen.height + at.y * Unit);

        /// A touch began while the pad is shown (screen pixels, origin bottom-left).
        public static void Begin(int touch, Vector2 pos, float now)
        {
            var owner = new Owner { Start = pos, Time = now };
            foreach (var b in Buttons)
                if ((pos - Place(b.At)).magnitude <= (b.Radius + 12) * Unit) { owner.Button = b; break; }
            if (owner.Button != null)
                owner.Button.Down = true;
            else
            {
                var s = pos.x < Screen.width / 2f ? Left : Right;
                if (s.Touch < 0)
                {
                    s.Touch = touch;
                    s.Origin = pos;
                    s.Value = Vector2.zero;
                    owner.Stick = s;
                }
            }
            Owners[touch] = owner;
        }

        public static void Move(int touch, Vector2 pos)
        {
            if (!Owners.TryGetValue(touch, out var o)) return;
            if ((pos - o.Start).magnitude > TapSlop * Unit) o.Moved = true;
            if (o.Stick == null) return;
            var d = pos - o.Stick.Origin;
            var travel = StickTravel * Unit;
            var len = d.magnitude;
            if (len > travel) { d *= travel / len; len = travel; }
            // Dead zone, then a power curve on the magnitude: small drags give small,
            // precise values; the edge of the circle is still full deflection.
            var m = len / travel;
            var output = m <= DeadZone ? 0f : Mathf.Pow((m - DeadZone) / (1 - DeadZone), o.Stick.Curve);
            o.Stick.Value = len > 0 ? d / travel * (output / m) : Vector2.zero;
        }

        /// The touch ended; returns true when it was a quick tap off the buttons (a click for TouchMouse).
        public static bool End(int touch, float now)
        {
            if (!Owners.TryGetValue(touch, out var o)) return false;
            Owners.Remove(touch);
            if (o.Button != null) o.Button.Down = false;
            if (o.Stick != null) { o.Stick.Touch = -1; o.Stick.Value = Vector2.zero; }
            return o.Button == null && !o.Moved && now - o.Time < TapSeconds;
        }

        static bool PhysicalGamepad()
        {
            foreach (var d in InputSystem.devices)
                if (d is Gamepad && d != _pad) return true;
            return false;
        }

        /// Called from the Input System's dynamic update.
        public static void Update()
        {
            if (!_enabled) return;
            var show = Cursor.lockState == CursorLockMode.Locked && !PhysicalGamepad();
            if (show != _visible) SetVisible(show);
            if (!_visible) return;

            var state = new GamepadState { leftStick = Left.Value, rightStick = Right.Value };
            foreach (var b in Buttons)
            {
                if (!b.Down) continue;
                if (b.Input == GamepadButton.LeftTrigger) state.leftTrigger = 1f;
                else if (b.Input == GamepadButton.RightTrigger) state.rightTrigger = 1f;
                else state = state.WithButton(b.Input);
            }
            InputSystem.QueueStateEvent(_pad, state);
            Draw();
        }

        static void SetVisible(bool show)
        {
            _visible = show;
            Owners.Clear();
            Left.Touch = Right.Touch = -1;
            Left.Value = Right.Value = Vector2.zero;
            foreach (var b in Buttons) b.Down = false;
            if (show)
            {
                if (_canvas == null) CreateCanvas();
                _canvas.SetActive(true);
            }
            else
            {
                InputSystem.QueueStateEvent(_pad, new GamepadState());  // release everything held
                if (_canvas != null) _canvas.SetActive(false);
            }
            Debug.Log(show ? "[recomp] touch gamepad shown" : "[recomp] touch gamepad hidden");
        }

        static void Draw()
        {
            foreach (var b in Buttons)
                b.Image.color = new Color(1f, 1f, 1f, b.Down ? 0.4f : 0.12f);
            foreach (var s in new[] { Left, Right })
            {
                var held = s.Touch >= 0;
                s.Base.gameObject.SetActive(held);
                s.Knob.gameObject.SetActive(held);
                if (!held) continue;
                s.Base.position = s.Origin;
                s.Knob.position = s.Origin + s.Value.normalized * Mathf.Min(1f, s.Value.magnitude) * StickTravel * Unit;
            }
        }

        static void CreateCanvas()
        {
            _canvas = new GameObject("RecompTouchPad");
            UnityEngine.Object.DontDestroyOnLoad(_canvas);
            var canvas = _canvas.AddComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            canvas.sortingOrder = SortingOrder;
            _circle = MakeCircle();
            var font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
            foreach (var b in Buttons)
            {
                var rt = Circle(b.Name, Place(b.At), b.Radius * Unit, 0.12f, out b.Image);
                var label = new GameObject("label", typeof(RectTransform));
                label.transform.SetParent(rt, false);
                var lr = (RectTransform)label.transform;
                lr.anchorMin = Vector2.zero;
                lr.anchorMax = Vector2.one;
                lr.offsetMin = lr.offsetMax = Vector2.zero;
                var text = label.AddComponent<Text>();
                text.font = font;
                text.text = b.Name;
                text.fontSize = Mathf.RoundToInt((b.Radius > 26 ? 20 : 13) * Unit);
                text.alignment = TextAnchor.MiddleCenter;
                text.color = new Color(1f, 1f, 1f, 0.75f);
                text.raycastTarget = false;
            }
            foreach (var s in new[] { Left, Right })
            {
                s.Base = Circle("stick", Vector2.zero, StickTravel * Unit, 0.06f, out _);
                s.Knob = Circle("knob", Vector2.zero, 28 * Unit, 0.35f, out _);
            }
        }

        static RectTransform Circle(string name, Vector2 center, float radius, float alpha, out Image image)
        {
            var go = new GameObject(name, typeof(RectTransform));
            go.transform.SetParent(_canvas.transform, false);
            var rt = (RectTransform)go.transform;
            rt.anchorMin = rt.anchorMax = Vector2.zero;
            rt.pivot = new Vector2(0.5f, 0.5f);
            rt.anchoredPosition = center;
            rt.sizeDelta = new Vector2(2 * radius, 2 * radius);
            image = go.AddComponent<Image>();
            image.sprite = _circle;
            image.color = new Color(1f, 1f, 1f, alpha);
            image.raycastTarget = false;
            return rt;
        }

        // A white disc with a brighter rim, tinted per use through Image.color.
        static Sprite MakeCircle()
        {
            const int size = 128;
            var tex = new Texture2D(size, size, TextureFormat.RGBA32, false);
            var px = new Color32[size * size];
            const float r = size / 2f - 1;
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    var d = new Vector2(x + 0.5f - size / 2f, y + 0.5f - size / 2f).magnitude;
                    var inside = Mathf.Clamp01(r - d + 0.5f);              // anti-aliased edge
                    var rim = Mathf.Clamp01(1f - Mathf.Abs(r - 2f - d) / 2f); // 2 px rim
                    px[y * size + x] = new Color32(255, 255, 255, (byte)(255 * inside * Mathf.Max(0.5f, rim * 2f)));
                }
            tex.SetPixels32(px);
            tex.Apply();
            return Sprite.Create(tex, new Rect(0, 0, size, size), new Vector2(0.5f, 0.5f));
        }
    }
}
