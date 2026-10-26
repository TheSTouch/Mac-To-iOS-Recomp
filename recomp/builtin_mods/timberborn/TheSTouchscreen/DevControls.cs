// The game's "Development controls" as a modal, on iPhones and iPads. The port's Dev key
// toggles developer mode as on a Mac (Alt+Shift+Z); while it is on, a key with a bug icon
// appears (Recomp.KeyButtons.AddAction: above the Dynamic Island on a phone held sideways,
// on top of the key stack elsewhere) and opens or closes
// the modal: a dimmed backdrop over everything, a green frame with gold borders and rounded
// corners (the game's square-large--green), the title, a close button, and the game's own
// panel (Common/DevPanel/DevPanel.uxml, DebuggingUI.DevPanel) moved inside it, so its filter,
// favourites and commands keep working: the filter first, the commands as full-width buttons
// about 44 pt tall with their favourite +/- beside them, scrolling. The game's title button
// (which folded the list) is hidden and the list always shown. A tap on the backdrop closes it
// too, and so does turning developer mode off.
using System;
using System.Collections.Generic;
using Timberborn.Debugging;
using Timberborn.SingletonSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.TheSTouchscreen
{
    public class DevControls : IPostLoadableSingleton, IUnloadableSingleton, IUpdatableSingleton
    {
        const string KeyLabel = "Debug";
        const float RowHeight = 80f, FontSize = 28f, HeadingSize = 34f, TitleSize = 38f, Gap = 12f;  // panel units (~0.54 pt each)
        static readonly Color Yellow = new Color(0.95f, 0.87f, 0.6f);

        static bool _devMode;  // read by the key's visibility, which outlives this scene

        readonly EventBus _eventBus;
        readonly DevModeManager _devModeManager;
        readonly HashSet<VisualElement> _styled = new HashSet<VisualElement>();
        VisualElement _root, _modal, _frame, _panel, _keyButton;
        float _nextCheck;

        public DevControls(EventBus eventBus, DevModeManager devModeManager)
        {
            _eventBus = eventBus;
            _devModeManager = devModeManager;
        }

        public void PostLoad()
        {
            foreach (var doc in UnityEngine.Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
                if (doc.rootVisualElement?.Q("GameUI") != null) _root = doc.rootVisualElement;
            if (_root == null)
            {
                Debug.Log("[TheSTouchscreen] dev controls: no GameUI");
                return;
            }
            _devMode = _devModeManager.Enabled;
            _eventBus.Register(this);
            KeyButtons.AddAction(KeyLabel, Toggle, () => _devMode);
            BuildModal();
            Debug.Log("[TheSTouchscreen] dev controls: bug key above the island while developer mode is on");
        }

        public void Unload() => _devMode = false;

        [OnEvent]
        public void OnDevModeToggled(DevModeToggledEvent devModeToggledEvent)
        {
            _devMode = devModeToggledEvent.Enabled;
            if (!_devMode) Show(false);
        }

        void Toggle() => Show(_modal != null && _modal.style.display == DisplayStyle.None);

        void Show(bool show)
        {
            if (_modal == null) return;
            if (show) Adopt();
            _modal.style.display = show ? DisplayStyle.Flex : DisplayStyle.None;
            if (show) _modal.BringToFront();
        }

        void BuildModal()
        {
            var common = Resources.Load<StyleSheet>("UI/Views/Common/CommonStyle");
            _modal = new VisualElement { name = "TheSTouchscreenDevModal" };
            var m = _modal.style;
            m.position = Position.Absolute;
            m.left = m.right = m.top = m.bottom = 0f;
            m.backgroundColor = new Color(0.04f, 0.06f, 0.05f, 0.55f);
            m.alignItems = Align.Center;
            m.justifyContent = Justify.Center;
            m.display = DisplayStyle.None;
            _modal.RegisterCallback<ClickEvent>(e => { if (e.target == _modal) Show(false); });

            _frame = NineSlice<VisualElement>("Timberborn.CoreUI.NineSliceVisualElement", common);
            var f = _frame.style;
            f.width = Length.Percent(62);
            f.height = Length.Percent(88);
            f.paddingLeft = f.paddingRight = f.paddingTop = f.paddingBottom = 20f;
            f.flexDirection = FlexDirection.Column;
            _modal.Add(_frame);

            var header = new VisualElement();
            header.style.flexDirection = FlexDirection.Row;
            header.style.alignItems = Align.Center;
            header.style.marginBottom = Gap;
            header.Add(BugIcon(56f));
            var title = new Label("Development controls");
            title.style.flexGrow = 1f;
            title.style.fontSize = TitleSize;
            title.style.color = Yellow;
            title.style.unityFontStyleAndWeight = FontStyle.Bold;
            title.style.marginLeft = Gap;
            header.Add(title);
            var close = NineSlice<Button>("Timberborn.CoreUI.NineSliceButton", common);
            close.text = "X";
            close.style.width = close.style.height = RowHeight;
            close.style.fontSize = FontSize;
            close.style.color = Yellow;
            close.clicked += () => Show(false);
            header.Add(close);
            _frame.Add(header);
            _root.Add(_modal);
        }

        // The game's panel into the frame, once it exists (DevPanel adds it to the bottom-left slot).
        void Adopt()
        {
            if (_panel != null && _panel.parent == _frame) return;
            _panel = _root.Q("DevPanel");
            if (_panel == null)
            {
                Debug.Log("[TheSTouchscreen] dev controls: the game's DevPanel is not there yet");
                return;
            }
            CarryStyles(_panel, _frame);
            _frame.Add(_panel);
            var p = _panel.style;
            p.position = Position.Relative;
            p.left = p.right = p.top = p.bottom = StyleKeyword.Auto;
            p.flexGrow = 1f;
            p.width = StyleKeyword.Auto;
            p.marginLeft = p.marginRight = p.marginTop = p.marginBottom = 0f;
            var titleButton = _panel.Q("DevPanelTitle");
            if (titleButton != null) titleButton.style.display = DisplayStyle.None;
            var content = _panel.Q("DevPanelContent");
            var filter = _panel.Q("DevPanelFilter");
            if (content != null)
            {
                content.style.flexGrow = 1f;
                content.style.width = StyleKeyword.Auto;
                content.style.maxHeight = StyleKeyword.None;
                if (filter != null) content.Insert(0, filter);  // the design puts the filter first
            }
            if (filter != null)
            {
                filter.style.height = RowHeight * 0.9f;
                filter.style.fontSize = FontSize;
                filter.style.marginBottom = Gap;
            }
            var scroll = _panel.Q<ScrollView>("DevPanelScroll");
            if (scroll != null)
            {
                scroll.style.flexGrow = 1f;
                scroll.style.maxHeight = StyleKeyword.None;
                scroll.style.height = StyleKeyword.Auto;
            }
            foreach (var name in new[] { "FavouritesLabel", "OtherLabel" })
            {
                var label = _panel.Q(name);
                if (label != null)
                {
                    label.style.fontSize = HeadingSize;
                    label.style.marginTop = label.style.marginBottom = Gap / 2f;
                }
            }
            Debug.Log("[TheSTouchscreen] dev controls: the game's panel moved into the modal");
        }

        public void UpdateSingleton()
        {
            if (_root == null || Time.unscaledTime < _nextCheck) return;
            _nextCheck = Time.unscaledTime + 0.5f;
            // The content stays shown (the game folds it from its hidden title button), and the
            // game rebuilds the command rows when favourites change: style the new ones.
            if (_panel != null && _panel.parent == _frame)
            {
                var content = _panel.Q("DevPanelContent");
                if (content != null && content.style.display != DisplayStyle.Flex) content.style.display = DisplayStyle.Flex;
                _panel.Query(className: "dev-panel-button").ForEach(StyleRow);
            }
            if (_keyButton == null) DecorateKey();
        }

        void StyleRow(VisualElement row)
        {
            if (!_styled.Add(row)) return;
            row.style.flexDirection = FlexDirection.Row;
            row.style.alignItems = Align.Center;
            row.style.marginBottom = Gap / 2f;
            var invoke = row.Q("Invoke");
            if (invoke != null)
            {
                var s = invoke.style;
                s.flexGrow = 1f;
                s.width = StyleKeyword.Auto;
                s.height = s.minHeight = RowHeight;
                s.fontSize = FontSize;
                s.unityTextAlign = TextAnchor.MiddleLeft;
                s.paddingLeft = 16f;
            }
            foreach (var name in new[] { "Add", "Remove" })
            {
                var b = row.Q(name);
                if (b == null) continue;
                b.style.width = b.style.height = b.style.minWidth = b.style.minHeight = RowHeight;
                b.style.marginLeft = Gap;
            }
        }

        // The bug icon on the key the shim drew for us.
        void DecorateKey()
        {
            foreach (var doc in UnityEngine.Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
            {
                if (doc.name != "RecompOverlay") continue;
                var key = doc.rootVisualElement?.Q<Button>("recomp-key-" + KeyLabel);
                if (key == null) return;
                key.text = "";
                key.style.alignItems = Align.Center;
                key.style.justifyContent = Justify.Center;
                var icon = BugIcon(0f);
                icon.style.width = icon.style.height = Length.Percent(70);
                key.Add(icon);
                _keyButton = key;
            }
        }

        // A bug drawn in the game's yellow: body, head, six legs, two antennae.
        static VisualElement BugIcon(float size)
        {
            var icon = new VisualElement { pickingMode = PickingMode.Ignore };
            if (size > 0f) icon.style.width = icon.style.height = size;
            icon.generateVisualContent += ctx =>
            {
                var r = ctx.visualElement.contentRect;
                var k = Mathf.Min(r.width, r.height) / 24f;
                if (!(k > 0f)) return;
                var o = r.center - new Vector2(12f, 12f) * k;
                Vector2 P(float x, float y) => o + new Vector2(x, y) * k;
                var p = ctx.painter2D;
                p.strokeColor = Yellow;
                p.lineWidth = 1.8f * k;
                p.lineCap = LineCap.Round;
                p.BeginPath();
                p.Arc(P(12f, 14.5f), 5.5f * k, Angle.Degrees(0f), Angle.Degrees(360f));
                p.Stroke();
                p.BeginPath();
                p.Arc(P(12f, 9f), 3f * k, Angle.Degrees(180f), Angle.Degrees(360f));
                p.Stroke();
                foreach (var (a, b) in new[]
                {
                    (P(12f, 9f), P(12f, 20f)), (P(6.5f, 12f), P(3.5f, 11f)), (P(6.5f, 15f), P(3f, 15f)),
                    (P(7f, 18f), P(4f, 20f)), (P(17.5f, 12f), P(20.5f, 11f)), (P(17.5f, 15f), P(21f, 15f)),
                    (P(17f, 18f), P(20f, 20f)), (P(10f, 6.5f), P(8f, 3.5f)), (P(14f, 6.5f), P(16f, 3.5f)),
                })
                {
                    p.BeginPath();
                    p.MoveTo(a);
                    p.LineTo(b);
                    p.Stroke();
                }
            };
            return icon;
        }

        // The game's nine-slice frame (green, gold border, rounded corners), by type name.
        static T NineSlice<T>(string typeName, StyleSheet common) where T : VisualElement, new()
        {
            T e = null;
            var type = Type.GetType(typeName + ", Timberborn.CoreUI");
            if (type != null && typeof(T).IsAssignableFrom(type))
            {
                try { e = (T)Activator.CreateInstance(type); }
                catch (Exception ex) { Debug.Log("[TheSTouchscreen] " + type.Name + ": " + ex.Message); }
            }
            if (e == null)
            {
                e = new T();
                e.style.backgroundColor = new Color(0.1f, 0.16f, 0.14f, 0.97f);
            }
            if (common != null) e.styleSheets.Add(common);
            e.AddToClassList("square-large--green");
            return e;
        }

        static void CarryStyles(VisualElement element, VisualElement to)
        {
            for (var e = element.parent; e != null; e = e.parent)
                for (int i = 0; i < e.styleSheets.count; i++)
                    if (!to.styleSheets.Contains(e.styleSheets[i])) to.styleSheets.Add(e.styleSheets[i]);
        }
    }
}
