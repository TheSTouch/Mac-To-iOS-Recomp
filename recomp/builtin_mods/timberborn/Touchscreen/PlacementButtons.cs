// Place and Rows, next to the rotate and flip buttons of the game's placement panel, which
// is shown while a block object tool (buildings, paths, platforms) is active. They are built
// like those buttons (Views/Common/ToolPanel/BlockObjectPlacementPanel.uxml in the game's
// StreamingAssets/Modding/UI.zip): the same button type and classes, a 20 px icon and a
// caption where the rotate button shows its key, with icons from the game's own UI.
using System;
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
        const string PlaceIcon = "UI/Images/Game/ico_buildit", RowsIcon = "UI/Images/Core/dragging-icon";
        static readonly Color Lit = new Color(0.45f, 0.95f, 0.5f);

        readonly EventBus _eventBus;
        Button _place, _rows;
        VisualElement _rowsIcon;
        Label _rowsCaption;
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
            _rowsIcon.style.unityBackgroundImageTintColor = _rowsShown ? Lit : StyleKeyword.Null;
            if (_rowsCaption != null) _rowsCaption.style.color = _rowsShown ? Lit : StyleKeyword.Null;
        }

        void Attach()
        {
            Button rotate = null;
            foreach (var doc in UnityEngine.Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
                if ((rotate = doc.rootVisualElement?.Q<Button>(RotateButton)) != null) break;
            if (rotate == null)
            {
                Debug.Log("[Touchscreen] no " + RotateButton + " button: Place and Rows not added");
                return;
            }
            _place = Create(rotate, "Place", PlaceIcon, () => Placement.Place(), out _, out _);
            _rows = Create(rotate, "Rows", RowsIcon, () => Placement.Rows = !Placement.Rows, out _rowsIcon, out _rowsCaption);
            rotate.parent.Add(_place);
            rotate.parent.Add(_rows);
            _rowsShown = false;
            Debug.Log("[Touchscreen] Place and Rows added to the placement panel");
        }

        static Button Create(Button like, string caption, string icon, Action clicked, out VisualElement image, out Label label)
        {
            // The rotate button is the game's NineSliceButton (internal): make one of its type.
            Button b;
            try { b = (Button)Activator.CreateInstance(like.GetType()); }
            catch (Exception e)
            {
                Debug.Log("[Touchscreen] " + like.GetType().Name + ": " + e.Message + "; using a plain button");
                b = new Button();
            }
            b.name = "Touchscreen" + caption;
            b.clicked += clicked;
            foreach (var c in like.GetClasses()) b.AddToClassList(c);
            image = new VisualElement();
            foreach (var child in like.Children())
                if (!(child is Label))
                    foreach (var c in child.GetClasses())
                        if (!c.Contains("--")) image.AddToClassList(c);  // the size, not the rotate image
            image.style.backgroundImage = Image(icon);
            b.Add(image);
            label = new Label(caption);
            var binding = like.Q<Label>("Binding");
            if (binding != null)
                foreach (var c in binding.GetClasses()) label.AddToClassList(c);
            b.Add(label);
            return b;
        }

        static StyleBackground Image(string path)
        {
            var texture = Resources.Load<Texture2D>(path);
            if (texture != null) return new StyleBackground(texture);
            var sprite = Resources.Load<Sprite>(path);
            if (sprite != null) return new StyleBackground(sprite);
            Debug.Log("[Touchscreen] no image " + path);
            return new StyleBackground(StyleKeyword.None);
        }
    }
}
