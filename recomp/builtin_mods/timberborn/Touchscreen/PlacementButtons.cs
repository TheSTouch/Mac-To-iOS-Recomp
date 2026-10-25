// Place and Rows, next to the rotate and flip buttons of the game's placement panel, which
// is shown while a block object tool (buildings, paths, platforms) is active.
using Timberborn.BlockObjectTools;
using Timberborn.SingletonSystem;
using Timberborn.ToolSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.Touchscreen
{
    public class PlacementButtons : ILoadableSingleton, IUpdatableSingleton
    {
        // The game's placement panel, found by its rotate button (BlockObjectPlacementPanel).
        const string RotateButton = "RotateClockwise";
        static readonly Color LitText = new Color(0.45f, 0.95f, 0.5f);

        readonly EventBus _eventBus;
        Button _place, _rows;
        bool _rowsShown;

        public PlacementButtons(EventBus eventBus)
        {
            _eventBus = eventBus;
        }

        public void Load()
        {
            _eventBus.Register(this);
        }

        [OnEvent]
        public void OnToolEntered(ToolEnteredEvent toolEnteredEvent)
        {
            Placement.Active = toolEnteredEvent.Tool is BlockObjectTool;
            if (Placement.Active && (_place == null || _place.panel == null)) Attach();
        }

        [OnEvent]
        public void OnToolExited(ToolExitedEvent toolExitedEvent)
        {
            Placement.Active = false;
        }

        public void UpdateSingleton()
        {
            if (_rows == null || Placement.Rows == _rowsShown) return;
            _rowsShown = Placement.Rows;
            _rows.style.color = _rowsShown ? LitText : StyleKeyword.Null;
        }

        void Attach()
        {
            Button rotate = null;
            foreach (var doc in Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
                if ((rotate = doc.rootVisualElement?.Q<Button>(RotateButton)) != null) break;
            if (rotate == null)
            {
                Debug.Log("[Touchscreen] no " + RotateButton + " button: Place and Rows not added");
                return;
            }
            _place = Create(rotate, "Place", () => Placement.Place());
            _rows = Create(rotate, "Rows", () => Placement.Rows = !Placement.Rows);
            rotate.parent.Add(_place);
            rotate.parent.Add(_rows);
            _rowsShown = false;
            Debug.Log("[Touchscreen] Place and Rows added to the placement panel");
        }

        // Styled like the game's rotate button, with a label instead of its icon.
        static Button Create(Button like, string label, System.Action clicked)
        {
            var b = new Button(clicked) { text = label, name = "Touchscreen" + label };
            foreach (var c in like.GetClasses()) b.AddToClassList(c);
            b.style.width = StyleKeyword.Auto;
            b.style.minWidth = like.resolvedStyle.width;
            b.style.paddingLeft = b.style.paddingRight = 8;
            b.style.fontSize = 14;
            b.style.unityFontStyleAndWeight = FontStyle.Bold;
            return b;
        }
    }
}
