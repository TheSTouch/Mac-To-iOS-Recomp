// Drives a virtual Input System mouse from touchscreen gestures, for desktop
// games that read Mouse.current and Keyboard.current on a device that has
// neither. Touch events are consumed so the game's UI only sees the mouse.
//
//   1 finger: tap = left click, drag = left drag
//   2 fingers: drag = middle drag, pinch = scroll wheel, quick tap = right click
//   3 fingers: drag = right drag
//   Esc button (top right): Escape key, see EscButton
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
        static ushort _tapButtons;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        public static void Install()
        {
            if (_mouse != null) return;
            _mouse = InputSystem.AddDevice<Mouse>("RecompTouchMouse");
            EscButton.Install();
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

        // Press now (or next frame if a release is still due), release one frame later.
        static void Tap(int buttons, string what)
        {
            Debug.Log("[recomp] " + what);
            _tapButtons = (ushort)buttons;
            _tapPending = true;
        }
    }
}
