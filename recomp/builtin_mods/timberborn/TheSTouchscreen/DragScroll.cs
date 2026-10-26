// Scrolling a ScrollView by dragging it with the mouse. UI Toolkit drag-scrolls only for touch and
// pen pointers; the port's touches reach the game's UI as the mouse unless the profile has
// "touch_ui" (Recomp.TouchMouse), and a real mouse can drag too. A vertical drag past a
// few units scrolls the view and takes the pointer from the button it started on, so the drag
// does not end as a click; a tap stays a click.
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.TheSTouchscreen
{
    class DragScroll
    {
        const float Threshold = 10f;  // panel units

        readonly ScrollView _view;
        readonly float _scale;
        int _pointer = -1;
        bool _dragging;
        float _startY, _startOffset;

        DragScroll(ScrollView view, float scale)
        {
            _view = view;
            _scale = scale;
        }

        /// scale: the view's own scale, to turn panel distances into its content's.
        public static void Attach(ScrollView view, float scale)
        {
            var d = new DragScroll(view, scale);
            view.RegisterCallback<PointerDownEvent>(d.Down, TrickleDown.TrickleDown);
            view.RegisterCallback<PointerMoveEvent>(d.Move, TrickleDown.TrickleDown);
            view.RegisterCallback<PointerUpEvent>(d.Up, TrickleDown.TrickleDown);
        }

        void Down(PointerDownEvent e)
        {
            if (e.pointerType != PointerType.mouse) return;  // touch and pen: the ScrollView's own
            _pointer = e.pointerId;
            _dragging = false;
            _startY = e.position.y;
            _startOffset = _view.scrollOffset.y;
        }

        void Move(PointerMoveEvent e)
        {
            if (e.pointerId != _pointer) return;
            var dy = (e.position.y - _startY) / _scale;
            if (!_dragging)
            {
                if (Mathf.Abs(dy) < Threshold) return;
                _dragging = true;
                _view.CapturePointer(_pointer);
            }
            _view.scrollOffset = new Vector2(_view.scrollOffset.x, _startOffset - dy);
            e.StopPropagation();
        }

        void Up(PointerUpEvent e)
        {
            if (e.pointerId != _pointer) return;
            if (_dragging)
            {
                _view.ReleasePointer(_pointer);
                e.StopPropagation();
            }
            _pointer = -1;
            _dragging = false;
        }
    }
}
