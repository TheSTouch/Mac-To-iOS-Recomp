// Drives a virtual Input System mouse from touchscreen gestures, for desktop
// games that read Mouse.current and Keyboard.current on a device that has
// neither. Touch events are consumed so the game's UI only sees the mouse.
//
//   1 finger: tap = left click, drag = left drag
//   2 fingers: drag = middle drag, pinch = scroll wheel, quick tap = right click
//   3 fingers: drag = right drag
//   Esc button (bottom left): Escape key, see EscButton
//   Text fields open the on-screen keyboard, see SoftKeyboard
//   In play, with no controller: an on-screen gamepad instead (opt-in), see TouchPad
//
// A real mouse or keyboard, when connected, keeps working alongside.
using System.Collections.Generic;
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

        enum Mode { None, Pending, Left, Multi }

        static Mouse _mouse;
        static readonly Dictionary<int, Vector2> Touches = new Dictionary<int, Vector2>();
        static Mode _mode;
        static float _modeStart;
        static Vector2 _start, _last, _lastPos;
        // _travel: centroid movement summed only over frames with an unchanged finger
        // count, so fingers landing or lifting at slightly different times (which
        // makes the centroid jump) do not turn a tap into a drag.
        static float _lastSpread, _travel;
        static bool _sawTouch;
        static readonly HashSet<int> EscTouches = new HashSet<int>();
        static int _maxFingers, _lastCount;
        static ushort _buttons;
        static bool _releaseNextFrame, _tapPending;
        static ushort _tapButtons, _loggedButtons;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Install()
        {
            if (_mouse != null) return;
            // Named "Mouse" like a desktop mouse: games store bindings as control paths,
            // and "/Mouse/leftButton" matches a device by name. Reuse one if it exists.
            _mouse = InputSystem.FindControl("/Mouse")?.device as Mouse ?? InputSystem.AddDevice<Mouse>("Mouse");
            Debug.Log("[recomp] driving mouse " + _mouse.name + "; devices: " + string.Join(", ", InputSystem.devices));
            EscButton.Install();
            TouchPad.Install();
            InputSystem.onEvent += OnEvent;
            InputSystem.onBeforeUpdate += OnBeforeUpdate;
            Debug.Log("[recomp] touch mouse installed");
        }

        static unsafe void OnEvent(InputEventPtr eventPtr, InputDevice device)
        {
            if (!(device is Touchscreen) || !eventPtr.IsA<StateEvent>()) return;
            var stateEvent = StateEvent.From(eventPtr);
            if (stateEvent->stateFormat != TouchState.Format) return;
            var touch = (TouchState*)stateEvent->state;
            if (!_sawTouch)
            {
                _sawTouch = true;
                Debug.Log("[recomp] first touch received");
            }
            eventPtr.handled = true;
            var id = touch->touchId;
            if (EscTouches.Contains(id))
            {
                if (touch->phase == UnityEngine.InputSystem.TouchPhase.Ended)
                {
                    EscTouches.Remove(id);
                    EscButton.Press();
                }
                else if (touch->phase == UnityEngine.InputSystem.TouchPhase.Canceled)
                    EscTouches.Remove(id);
                return;
            }
            if (touch->phase == UnityEngine.InputSystem.TouchPhase.Began && EscButton.Contains(touch->position))
            {
                EscTouches.Add(id);
                return;
            }
            // Touches that begin while the gamepad is shown stay with it until they end.
            if (TouchPad.Owns(id) || (touch->phase == UnityEngine.InputSystem.TouchPhase.Began && TouchPad.Visible))
            {
                var now = Time.realtimeSinceStartup;
                switch (touch->phase)
                {
                    case UnityEngine.InputSystem.TouchPhase.Began: TouchPad.Begin(id, touch->position, now); break;
                    case UnityEngine.InputSystem.TouchPhase.Moved:
                    case UnityEngine.InputSystem.TouchPhase.Stationary: TouchPad.Move(id, touch->position); break;
                    default:
                        if (TouchPad.End(id, now)) ClickAt(touch->position);
                        break;
                }
                return;
            }
            switch (touch->phase)
            {
                case UnityEngine.InputSystem.TouchPhase.Began:
                case UnityEngine.InputSystem.TouchPhase.Moved:
                case UnityEngine.InputSystem.TouchPhase.Stationary:
                    Touches[touch->touchId] = touch->position;
                    break;
                default:
                    Touches.Remove(touch->touchId);
                    break;
            }
        }

        static void OnBeforeUpdate()
        {
            if (InputState.currentUpdateType != InputUpdateType.Dynamic) return;
            var now = Time.realtimeSinceStartup;
            EscButton.Update(now);
            SoftKeyboard.Update(now);
            TouchPad.Update();
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
                    if (n == 1) Begin(Mode.Pending, center, now);
                    else if (n > 1) Begin(Mode.Multi, center, now);
                    break;
                case Mode.Pending:
                    if (n > 1) Begin(Mode.Multi, center, now);
                    else if (n == 0) { Tap(1 << (int)MouseButton.Left, "left click"); _mode = Mode.None; }
                    else if (now - _modeStart > PendingSeconds || (center - _start).magnitude > MoveThreshold)
                    {
                        _mode = Mode.Left;
                        _buttons = 1 << (int)MouseButton.Left;
                    }
                    break;
                case Mode.Left:
                    if (n == 0) { _buttons = 0; _mode = Mode.None; }
                    break;
                case Mode.Multi:
                    _maxFingers = Mathf.Max(_maxFingers, n);
                    if (n == 0)
                    {
                        _buttons = 0;
                        if (_maxFingers == 2 && now - _modeStart < TapSeconds && _travel < MoveThreshold)
                            Tap(1 << (int)MouseButton.Right, "right click (two-finger tap)");
                        _mode = Mode.None;
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
            _maxFingers = Touches.Count;
            _lastSpread = 0f;
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
