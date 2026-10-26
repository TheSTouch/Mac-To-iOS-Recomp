// Drives a virtual Input System mouse from touchscreen gestures, for desktop
// games that read Mouse.current and Keyboard.current on a device that has
// neither. Touch events are consumed so the game's UI only sees the mouse,
// except in games that opt into touch UI (the profile's "touch_ui"): there a touch
// that starts on the game's UI is left to it, as a real touch (taps, drag-scrolling,
// no hover), and the mouse stays where the last touch on the world left it.
// A game mod can also claim the input (Claimed; Timberborn's TheSTouchscreen mod in its game
// scene): the mouse is then parked off screen and left alone, touches that begin on the
// game's UI go to it as touches, and the others are the mod's (WorldTouches) to turn into
// the game's world input itself.
//
//   1 finger: tap = left click, drag = left drag
//   2 fingers: drag = middle drag, pinch = scroll wheel, quick tap = right click
//   3 fingers: drag = right drag
//   Apple Pencil: one more finger while its tip is down (iOS reports it as a Pen, not a touch)
//   Key buttons (bottom left): Esc and the profile's extra keys, see KeyButtons
//   While a game mod says a building is being placed: 1 finger on the world aims instead of
//   clicking, and the mod's Place button clicks where it aimed, see Placement
//   Text fields open the on-screen keyboard, see SoftKeyboard
//   In play, with no controller: an on-screen gamepad instead (opt-in), see TouchPad
//
// A real mouse or keyboard, when connected, keeps working alongside.
using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;

namespace Recomp
{
    public static class TouchMouse
    {
        const float PendingSeconds = 0.08f;   // wait this long for a second finger before pressing left
        const float MoveThreshold = 12f;      // pixels before a gesture counts as a drag
        const float TapSeconds = 0.3f;
        const float ScrollPerPixel = 0.5f;    // pinch spread change -> scroll units
        const int ProbeFrames = 2;            // while placing: frames the mouse sits on a new touch before the game's UI is asked

        enum Mode { None, Pending, Left, Multi, Probe, Aim }

        static Mouse _mouse;
        static readonly Dictionary<int, Vector2> Touches = new Dictionary<int, Vector2>();
        static readonly HashSet<int> UiTouches = new HashSet<int>();  // touch UI: touches left to the game's UI
        static bool _touchUi, _claimed, _park;

        [Serializable]
        class Config { public bool touchUi; }
        static Mode _mode;
        static float _modeStart;
        static Vector2 _start, _last, _lastPos;
        // _travel: centroid movement summed only over frames with an unchanged finger
        // count, so fingers landing or lifting at slightly different times (which
        // makes the centroid jump) do not turn a tap into a drag.
        static float _lastSpread, _travel;
        static bool _sawTouch;
        static readonly Dictionary<int, int> KeyTouches = new Dictionary<int, int>();  // touch id -> key button
        static int _maxFingers, _lastCount;
        static ushort _buttons;
        static bool _releaseNextFrame, _tapPending;
        static ushort _tapButtons, _loggedButtons;
        static bool _penDown, _sawPen;
        // The spot on the map the last touch there lifted at (while placing: where the player aimed,
        // the ghost stays there), whether the mouse goes back there once a touch on the game's UI
        // is over (so the game sees it leave: no lingering hover, tooltip or hover-preview), and
        // the frames left before Place clicks there.
        static Vector2 _aim;
        static bool _hasAim, _restoreAim;
        static int _restoreWait, _probeFrames, _placeIn;

        /// A game mod drives the game's world input itself: no mouse (parked off screen, no
        /// buttons), touches on the game's UI stay touches, the rest are WorldTouches. Key buttons
        /// and the on-screen keyboard keep working. False (menus, other games): the mouse as usual.
        public static bool Claimed
        {
            get => _claimed;
            set
            {
                if (value == _claimed) return;
                _claimed = value;
                Touches.Clear();
                UiTouches.Clear();
                _mode = Mode.None;
                _buttons = 0;
                _tapPending = _releaseNextFrame = _restoreAim = false;
                _placeIn = 0;
                _park = value;
                Debug.Log("[recomp] input " + (value ? "claimed by a game mod: no mouse, touches on the UI stay touches" : "released: touches drive the mouse"));
            }
        }

        /// While Claimed: the touches on the world (not on the game's UI or a key button), by id,
        /// at their latest position (Input System pixels, origin bottom-left). The pencil is PenId.
        public static IReadOnlyDictionary<int, Vector2> WorldTouches => Touches;

        public const int PenId = -1;          // the pencil's slot among the touches (touch ids are positive)

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Install()
        {
            if (_mouse != null) return;
            // Named "Mouse" like a desktop mouse: games store bindings as control paths,
            // and "/Mouse/leftButton" matches a device by name. Reuse one if it exists.
            _mouse = InputSystem.FindControl("/Mouse")?.device as Mouse ?? InputSystem.AddDevice<Mouse>("Mouse");
            Debug.Log("[recomp] driving mouse " + _mouse.name + "; devices: " + string.Join(", ", InputSystem.devices));
            KeyButtons.Install();
            TouchPad.Install();
            try
            {
                var path = Path.Combine(Application.streamingAssetsPath, "recomp.json");
                _touchUi = File.Exists(path) && JsonUtility.FromJson<Config>(File.ReadAllText(path)).touchUi;
            }
            catch (Exception e)
            {
                Debug.Log("[recomp] touch UI: cannot read recomp.json: " + e.Message);
            }
            InputSystem.onEvent += OnEvent;
            InputSystem.onBeforeUpdate += OnBeforeUpdate;
            Debug.Log("[recomp] touch mouse installed" + (_touchUi ? "; touches on the game's UI stay touches" : ""));
        }

        static unsafe void OnEvent(InputEventPtr eventPtr, InputDevice device)
        {
            if (!eventPtr.IsA<StateEvent>()) return;
            var stateEvent = StateEvent.From(eventPtr);
            if (device is Pen && stateEvent->stateFormat == PenState.Format)
            {
                // Games that read only the mouse never see the pencil, while UI that takes any
                // pointer does: consume it like a touch so both see the same mouse.
                var pen = (PenState*)stateEvent->state;
                if (!_sawPen)
                {
                    _sawPen = true;
                    Debug.Log("[recomp] first pencil event");
                }
                var down = (pen->buttons & (1 << (int)PenButton.Tip)) != 0;
                var penPhase = !down ? UnityEngine.InputSystem.TouchPhase.Ended
                    : _penDown ? UnityEngine.InputSystem.TouchPhase.Moved : UnityEngine.InputSystem.TouchPhase.Began;
                var wasDown = _penDown;
                _penDown = down;
                if ((down || wasDown) && _claimed && ToUi(PenId, penPhase, pen->position)) return;
                eventPtr.handled = true;
                if (down || wasDown) OnPointer(PenId, penPhase, pen->position);
                return;
            }
            if (!(device is Touchscreen) || stateEvent->stateFormat != TouchState.Format) return;
            var touch = (TouchState*)stateEvent->state;
            if (!_sawTouch)
            {
                _sawTouch = true;
                Debug.Log("[recomp] first touch received");
            }
            if ((_touchUi || _claimed) && ToUi(touch->touchId, touch->phase, touch->position)) return;
            eventPtr.handled = true;
            OnPointer(touch->touchId, touch->phase, touch->position);
        }

        // Touch UI: whether this touch belongs to the game's UI (decided when it begins: on a
        // panel, not on a key button or the gamepad), so the event goes on to it unconsumed.
        static bool ToUi(int id, UnityEngine.InputSystem.TouchPhase phase, Vector2 position)
        {
            if (UiTouches.Contains(id))
            {
                if (phase == UnityEngine.InputSystem.TouchPhase.Ended || phase == UnityEngine.InputSystem.TouchPhase.Canceled)
                    UiTouches.Remove(id);
                return true;
            }
            if (phase != UnityEngine.InputSystem.TouchPhase.Began || KeyButtons.At(position) >= 0 || TouchPad.Visible
                || Touches.Count > 0 || !Placement.UiAt(position))
                return false;
            UiTouches.Add(id);
            return true;
        }

        static void OnPointer(int id, UnityEngine.InputSystem.TouchPhase phase, Vector2 position)
        {
            if (KeyTouches.TryGetValue(id, out var key))
            {
                if (phase == UnityEngine.InputSystem.TouchPhase.Ended)
                {
                    KeyTouches.Remove(id);
                    KeyButtons.Press(key);
                }
                else if (phase == UnityEngine.InputSystem.TouchPhase.Canceled)
                    KeyTouches.Remove(id);
                return;
            }
            if (phase == UnityEngine.InputSystem.TouchPhase.Began && (key = KeyButtons.At(position)) >= 0)
            {
                KeyTouches[id] = key;
                return;
            }
            // Touches that begin while the gamepad is shown stay with it until they end.
            if (TouchPad.Owns(id) || (phase == UnityEngine.InputSystem.TouchPhase.Began && TouchPad.Visible))
            {
                var now = Time.realtimeSinceStartup;
                switch (phase)
                {
                    case UnityEngine.InputSystem.TouchPhase.Began: TouchPad.Begin(id, position, now); break;
                    case UnityEngine.InputSystem.TouchPhase.Moved:
                    case UnityEngine.InputSystem.TouchPhase.Stationary: TouchPad.Move(id, position); break;
                    default:
                        if (TouchPad.End(id, now)) ClickAt(position);
                        break;
                }
                return;
            }
            switch (phase)
            {
                case UnityEngine.InputSystem.TouchPhase.Began:
                case UnityEngine.InputSystem.TouchPhase.Moved:
                case UnityEngine.InputSystem.TouchPhase.Stationary:
                    Touches[id] = position;
                    break;
                default:
                    Touches.Remove(id);
                    break;
            }
        }

        static void OnBeforeUpdate()
        {
            if (InputState.currentUpdateType != InputUpdateType.Dynamic) return;
            var now = Time.realtimeSinceStartup;
            KeyButtons.Update(now);
            SoftKeyboard.Update(now);
            TouchPad.Update();
            if (_claimed)
            {
                // The game mod reads WorldTouches; the mouse leaves the screen once, so nothing
                // under its last spot stays hovered, and then gets no state at all.
                if (_park)
                {
                    _park = false;
                    InputSystem.QueueStateEvent(_mouse, new MouseState { position = new Vector2(-10000f, -10000f) });
                }
                return;
            }
            var n = Touches.Count;
            var center = Vector2.zero;
            foreach (var p in Touches.Values) center += p;
            if (n > 0) center /= n;
            var spread = 0f;
            foreach (var p in Touches.Values) spread += (p - center).magnitude;
            if (n > 1) spread /= n;

            var scroll = 0f;
            if (_releaseNextFrame)
            {
                _buttons = 0;
                _releaseNextFrame = false;
            }
            else if (_tapPending)
            {
                _buttons = _tapButtons;
                _tapPending = false;
                _releaseNextFrame = true;
            }

            switch (_mode)
            {
                case Mode.None:
                    if (n == 1) Begin(Placement.Active && !Placement.Rows ? Mode.Probe : Mode.Pending, center, now);
                    else if (n > 1) Begin(Mode.Multi, center, now);
                    break;
                case Mode.Probe:
                    // Placing a building: the mouse has moved onto the finger without a button.
                    // Ask the game's UI, as the game does, once it has seen the mouse there:
                    // menus get a click, the world aims.
                    if (n > 1) { Begin(Mode.Multi, center, now); break; }
                    if (n == 1 && ++_probeFrames < ProbeFrames) break;
                    if (Placement.MouseOverUI(_lastPos))
                    {
                        if (n == 0) { Tap(1 << (int)MouseButton.Left, "left click"); End(); }
                        else _mode = Mode.Pending;  // keeps its start: the press still comes 80 ms after the touch
                    }
                    else if (n == 0)
                    {
                        _aim = _lastPos;
                        _hasAim = true;
                        _mode = Mode.None;
                    }
                    else _mode = Mode.Aim;
                    break;
                case Mode.Aim:
                    if (n > 1) Begin(Mode.Multi, center, now);
                    else if (n == 0)
                    {
                        _aim = _lastPos;
                        _hasAim = true;
                        _mode = Mode.None;
                    }
                    break;
                case Mode.Pending:
                    if (n > 1) Begin(Mode.Multi, center, now);
                    else if (n == 0) { Tap(1 << (int)MouseButton.Left, "left click"); End(); }
                    else if (now - _modeStart > PendingSeconds || (center - _start).magnitude > MoveThreshold)
                    {
                        _mode = Mode.Left;
                        _buttons = 1 << (int)MouseButton.Left;
                    }
                    break;
                case Mode.Left:
                    if (n == 0) { _buttons = 0; End(); }
                    break;
                case Mode.Multi:
                    _maxFingers = Mathf.Max(_maxFingers, n);
                    if (n == 0)
                    {
                        _buttons = 0;
                        if (_maxFingers == 2 && now - _modeStart < TapSeconds && _travel < MoveThreshold)
                            Tap(1 << (int)MouseButton.Right, "right click (two-finger tap)");
                        End(camera: true);
                        break;
                    }
                    if (n == _lastCount)
                        _travel += (center - _last).magnitude;
                    if (n >= 3)
                        _buttons = 1 << (int)MouseButton.Right;
                    else if (n == 2 && _maxFingers == 2 && _travel > MoveThreshold)
                        _buttons = 1 << (int)MouseButton.Middle;
                    if (n == 2 && _lastSpread > 0f)
                        scroll = (spread - _lastSpread) * ScrollPerPixel;
                    break;
            }

            if (_placeIn > 0 && n == 0 && --_placeIn == 0) Tap(1 << (int)MouseButton.Left, "place");
            // Back to the aimed spot a frame after the click let go, so the ghost reappears there.
            if (_restoreAim && n == 0 && !_tapPending && !_releaseNextFrame && _buttons == 0 && ++_restoreWait > 1)
            {
                _restoreAim = false;
                _lastPos = _aim;
            }
            // Touch UI: a one-finger gesture on the world does not take the mouse over the game's UI
            // (it would hover its buttons); the mouse waits at its last spot off the UI.
            if (_touchUi && n == 1 && _mode != Mode.Probe && _mode != Mode.Multi && Placement.UiAt(center))
                center = _lastPos;
            var pos = n > 0 ? center : _lastPos;
            // When the finger count changes the centroid jumps; do not turn that into motion.
            var delta = n > 0 && n == _lastCount ? pos - _last : Vector2.zero;
            _last = pos;
            _lastPos = pos;
            _lastSpread = n == 2 ? spread : 0f;
            _lastCount = n;

#if RECOMP_UGUI
            if (_buttons != _loggedButtons)
            {
                PointerDiagnostics.Log(_buttons > _loggedButtons ? "down" : "up", pos, _buttons);
                _loggedButtons = _buttons;
            }
#endif
            var state = new MouseState { position = pos, delta = delta, scroll = new Vector2(0f, scroll), buttons = _buttons };
            InputSystem.QueueStateEvent(_mouse, state);
        }

        static void Begin(Mode mode, Vector2 center, float now)
        {
            _mode = mode;
            _modeStart = now;
            _start = center;
            _travel = 0f;
            _probeFrames = 0;
            _maxFingers = Touches.Count;
            _lastSpread = 0f;
        }

        // A gesture other than aiming is over. A touch that lifted on the map leaves the mouse there
        // and becomes the spot to return to; after a touch on the game's UI (or a camera gesture
        // while placing) the mouse goes back to that spot.
        static void End(bool camera = false)
        {
            _mode = Mode.None;
            if (!camera && !Placement.MouseOverUI(_lastPos))
            {
                _aim = _lastPos;
                _hasAim = true;
            }
            else if (_hasAim && (!camera || Placement.Active))
            {
                _restoreAim = true;
                _restoreWait = 0;
            }
        }

        // Placement.Place: back to the aimed spot, and click there once the game has seen the mouse
        // leave the Place button (it skips a click while the mouse is over its UI).
        internal static bool PlaceAtAim()
        {
            if (!_hasAim)
            {
                Debug.Log("[recomp] place: nothing aimed at yet");
                return false;
            }
            _last = _lastPos = _aim;
            _restoreAim = false;
            _placeIn = 2;
            return true;
        }

        // Placing starts or stops: the ghost starts at the last spot touched on the map.
        internal static void ResetAim()
        {
            _placeIn = 0;
            if (_hasAim && Touches.Count == 0)
            {
                _restoreAim = true;
                _restoreWait = 0;
            }
        }

        // A left click at a spot, for taps the gamepad passes on.
        static void ClickAt(Vector2 pos)
        {
            _last = _lastPos = pos;
            Tap(1 << (int)MouseButton.Left, "left click (from the touch gamepad)");
        }

        // Press now (or next frame if a release is still due), release one frame later.
        static void Tap(int buttons, string what)
        {
            Debug.Log("[recomp] " + what);
            _tapButtons = (ushort)buttons;
            _tapPending = true;
        }
    }
}
