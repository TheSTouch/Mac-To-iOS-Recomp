// The game's world input from touches, in the game scene (iPhone and iPad). The port's shim
// stops emulating a mouse (Recomp.TouchMouse.Claimed): touches that begin on the game's UI go
// to it as real touches, so no button is ever hovered, and the rest arrive here
// (TouchMouse.WorldTouches). The game reads its mouse only through MouseController and
// InputService, which InputPatches answer from this class:
//   pointer (MouseController.Position): the finger on the world, else where the last one was;
//   1 finger: tap = main button down then up at the finger; drag = main button held while it
//     moves (paths, areas) when a tool is active, else the camera pans under the finger;
//   while placing a building (Recomp.Placement.Active): 1 finger only aims (the ghost follows,
//     no click), Place clicks at the aim, and with Rows on a drag places a row as above;
//   2 fingers: pan, pinch zoom and twist rotate, through CameraService; a quick tap = cancel
//     (the game's short right click);
//   MouseOverUI: the game's UI under the pointer, so it ignores world clicks under its panels.
// Menus before the game scene keep the shim's mouse.
using System.Collections.Generic;
using Timberborn.CameraSystem;
using Timberborn.SingletonSystem;
using Timberborn.ToolSystem;
using UnityEngine;

namespace Recomp.Touchscreen
{
    public class WorldInput : ILoadableSingleton, IUnloadableSingleton, IUpdatableSingleton
    {
        const float TapSeconds = 0.3f;
        const float TwistDegrees = 10f;    // a twist turns the camera once the fingers have turned this far

        // The mouse keys of the game's key bindings (InputService).
        internal const string MainKey = "MouseLeft", CancelKey = "MouseRight", MiddleKey = "MouseMiddle";

        enum Mode { None, Pending, Held, Pan, Aim, Multi }

        internal static WorldInput Current;

        readonly CameraService _cameraService;
        readonly ToolService _toolService;
        readonly Dictionary<int, Vector2> _fingers = new Dictionary<int, Vector2>();
        Mode _mode;
        int _frame = -1, _maxFingers;
        float _modeStart, _travel, _twist, _moveThreshold;
        bool _rotating, _dragged;
        Vector2 _pointer, _start, _last;
        Vector2? _pair;  // the vector between two fingers, last frame
        float _lastSpread;
        int _lastCount;
        // The game's mouse buttons this frame: main (down, held, up) and cancel (down, up).
        bool _mainDown, _mainHeld, _mainUp, _cancelDown, _cancelUp;
        int _tapFrames, _cancelFrames;  // 2: down this frame, 1: up this frame
        int _placeIn;                    // Place: frames until the click at the aim
        bool _overUi;
        int _overUiFrame = -1;

        public WorldInput(CameraService cameraService, ToolService toolService)
        {
            _cameraService = cameraService;
            _toolService = toolService;
        }

        public void Load()
        {
            Current = this;
            _pointer = new Vector2(Screen.width / 2f, Screen.height / 2f);
            // A drag starts past about 1.5 mm, whatever the screen's density.
            _moveThreshold = Mathf.Max(12f, (Screen.dpi > 0f ? Screen.dpi : 326f) * 0.06f);
            TouchMouse.Claimed = true;
            Debug.Log($"[Touchscreen] world input from touches (drag past {_moveThreshold:0} px); the game's UI gets real touches");
        }

        public void Unload()
        {
            if (Current == this) Current = null;
            TouchMouse.Claimed = false;
            Debug.Log("[Touchscreen] world input released: the mouse again");
        }

        internal static bool Active => Current != null && TouchMouse.Claimed;

        // Every frame too, so a short tap is seen even in a frame where the game asks nothing.
        public void UpdateSingleton() => Step();

        internal Vector2 Pointer
        {
            get { Step(); return _pointer; }
        }

        internal bool MouseOverUI
        {
            get
            {
                Step();
                if (_overUiFrame != Time.frameCount)
                {
                    _overUiFrame = Time.frameCount;
                    _overUi = Placement.UiAt(_pointer);
                }
                return _overUi;
            }
        }

        /// The game asks for one of its mouse keys: the state this frame, or null for other keys.
        internal bool? Key(string id, KeyQuery query)
        {
            if (id != MainKey && id != CancelKey && id != MiddleKey) return null;
            Step();
            if (id == MiddleKey) return false;  // the camera moves through CameraService instead
            if (id == CancelKey)
                return query == KeyQuery.Down ? _cancelDown
                    : query == KeyQuery.Up || query == KeyQuery.UpAfterShortHeld ? _cancelUp
                    : query == KeyQuery.Held && _cancelDown;
            switch (query)
            {
                case KeyQuery.Down: return _mainDown;
                case KeyQuery.Held: return _mainHeld;
                case KeyQuery.Up: return _mainUp;
                case KeyQuery.UpAfterShortHeld: return _mainUp && !_dragged;
                default: return _mainHeld && _mode == Mode.Held && Time.unscaledTime - _modeStart > 0.2f;
            }
        }

        /// Place: a click where the player last aimed.
        internal bool Place()
        {
            if (_placeIn > 0 || _tapFrames > 0) return false;
            _placeIn = 1;
            Debug.Log($"[Touchscreen] place at {_pointer}");
            return true;
        }

        // Once per frame, on the first question the game asks: the fingers, then the buttons.
        void Step()
        {
            if (_frame == Time.frameCount) return;
            _frame = Time.frameCount;
            _fingers.Clear();
            foreach (var t in TouchMouse.WorldTouches) _fingers[t.Key] = t.Value;
            var n = _fingers.Count;
            var center = Vector2.zero;
            foreach (var p in _fingers.Values) center += p;
            if (n > 0) center /= n;
            var now = Time.unscaledTime;

            // A tap's or Place's press lasts one frame, its release the next.
            _mainDown = _mainUp = _cancelDown = _cancelUp = false;
            if (_tapFrames > 0 && --_tapFrames == 0) { _mainUp = true; _mainHeld = false; }
            if (_cancelFrames > 0 && --_cancelFrames == 0) _cancelUp = true;
            if (_placeIn > 0 && n == 0 && --_placeIn == 0) Click("place");

            switch (_mode)
            {
                case Mode.None:
                    if (n == 1) Begin(Mode.Pending, center, now);
                    else if (n > 1) Begin(Mode.Multi, center, now);
                    break;
                case Mode.Pending:
                    if (n > 1) { Begin(Mode.Multi, center, now); break; }
                    _pointer = Clamp(n == 1 ? center : _last);
                    if (n == 0)
                    {
                        if (!Aiming) Click("tap");
                        _mode = Mode.None;
                    }
                    else if ((center - _start).magnitude > _moveThreshold)
                    {
                        if (Aiming) _mode = Mode.Aim;
                        else if (ToolDrags)
                        {
                            // The press goes where the finger landed, then follows it.
                            _mode = Mode.Held;
                            _modeStart = now;
                            _dragged = true;
                            _pointer = Clamp(_start);
                            _mainDown = _mainHeld = true;
                            Debug.Log("[Touchscreen] drag with the tool " + _toolService.ActiveTool?.GetType().Name);
                        }
                        else _mode = Mode.Pan;
                    }
                    break;
                case Mode.Aim:
                    if (n > 1) { Begin(Mode.Multi, center, now); break; }
                    if (n == 1) _pointer = Clamp(center);
                    else _mode = Mode.None;
                    break;
                case Mode.Held:
                    if (n > 0) _pointer = Clamp(_fingers.Count == 1 ? center : _pointer);
                    if (n == 0)
                    {
                        _mainHeld = false;
                        _mainUp = true;
                        _mode = Mode.None;
                    }
                    break;
                case Mode.Pan:
                    if (n > 1) { Begin(Mode.Multi, center, now); break; }
                    if (n == 0) { _mode = Mode.None; break; }
                    Grab(_last, center);
                    break;
                case Mode.Multi:
                    _maxFingers = Mathf.Max(_maxFingers, n);
                    if (n == 0)
                    {
                        if (_maxFingers == 2 && now - _modeStart < TapSeconds && _travel < _moveThreshold)
                        {
                            _cancelDown = true;
                            _cancelFrames = 1;
                            Debug.Log("[Touchscreen] cancel (two-finger tap)");
                        }
                        _mode = Mode.None;
                        break;
                    }
                    if (n == _lastCount) _travel += (center - _last).magnitude;
                    if (n != _lastCount) { _pair = null; _lastSpread = 0f; break; }
                    Grab(_last, center);
                    if (n == 2) PinchAndTwist();
                    break;
            }
            _last = center;
            _lastCount = n;
        }

        void Begin(Mode mode, Vector2 center, float now)
        {
            _mode = mode;
            _modeStart = now;
            _start = _last = center;
            _travel = _twist = 0f;
            _rotating = _dragged = false;
            _pair = null;
            _lastSpread = 0f;
            _maxFingers = _fingers.Count;
            if (mode == Mode.Pending) _pointer = Clamp(center);
        }

        // Placing a building without Rows: a finger moves the ghost, Place clicks.
        static bool Aiming => Placement.Active && !Placement.Rows;

        // A drag is the tool's (paths, areas, rows) unless the default tool (selection) is on.
        bool ToolDrags => _toolService.ActiveTool != null && !_toolService.IsDefaultToolActive;

        void Click(string what)
        {
            _mainDown = _mainHeld = true;
            _tapFrames = 1;
            Debug.Log($"[Touchscreen] {what} at {_pointer}");
        }

        // The map point under `from` moves to `to`: the camera's target shifts by the difference
        // between the two points on the ground plane at the target's height.
        void Grab(Vector2 from, Vector2 to)
        {
            if ((to - from).sqrMagnitude < 0.01f) return;
            var plane = new Plane(Vector3.up, new Vector3(0f, _cameraService.Target.y, 0f));
            var a = _cameraService.ScreenPointToPreciseRayInWorldSpace(from);
            var b = _cameraService.ScreenPointToPreciseRayInWorldSpace(to);
            if (!plane.Raycast(a, out var ea) || !plane.Raycast(b, out var eb)) return;
            var delta = a.GetPoint(ea) - b.GetPoint(eb);
            _cameraService.MoveTargetTo(_cameraService.Target + new Vector3(delta.x, 0f, delta.z));
        }

        // Two fingers: the distance to the map scales with their spread, and once they have turned
        // far enough the camera turns with them.
        void PinchAndTwist()
        {
            Vector2 a = default, b = default;
            var i = 0;
            foreach (var p in _fingers.Values)
                if (i++ == 0) a = p;
                else b = p;
            var pair = b - a;
            var spread = pair.magnitude;
            if (_lastSpread > 1f && spread > 1f)
            {
                var distance = _cameraService.OffsetFromTarget.magnitude;
                _cameraService.SetZoomLevel(distance * _lastSpread / spread, 0f);
            }
            _lastSpread = spread;
            if (_pair.HasValue)
            {
                var turn = Vector2.SignedAngle(_pair.Value, pair);
                _twist += turn;
                if (!_rotating && Mathf.Abs(_twist) > TwistDegrees)
                {
                    _rotating = true;
                    turn = _twist;
                }
                if (_rotating) _cameraService.ModifyHorizontalAngle(turn);
            }
            _pair = pair;
        }

        // The game pans the camera when the mouse touches a screen edge (edge panning).
        static Vector2 Clamp(Vector2 p) =>
            new Vector2(Mathf.Clamp(p.x, 4f, Screen.width - 5f), Mathf.Clamp(p.y, 4f, Screen.height - 5f));
    }

    enum KeyQuery { Down, Held, LongHeld, Up, UpAfterShortHeld }
}
