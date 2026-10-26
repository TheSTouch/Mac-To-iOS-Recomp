// The game's HUD laid out for an iPhone's short screen (iPhone only; an iPad keeps the
// game's own layout). Every HUD panel sits in one of the named slots of the game's
// Views/Common/GameUI.uxml (Top-left, Top-right, Top-bar, Bottom-bar, ...); this moves
// whole panels between containers and leaves the game's references to them intact, so the
// game goes on updating and showing them as usual. Sizes are in the panel's units: on an
// iPhone 17 at the game's largest UI scale one unit is about 0.54 pt, so Apple's 44 pt
// touch target is about 80 units.
// - The HUD keeps inside the safe area: clear of the Dynamic Island and the home indicator.
// - Top strip, 80 units tall: a Colony tab, the goods counters drawn 1.45 times larger with
//   their breakdowns closed, the speed buttons at 80 x 66, and a View tab at the right end.
//   Date and weather stay under the speed buttons.
// - The bottom bar becomes a column on the left edge, drawn 1.6 times larger and scrolled by
//   dragging: the general tools (Select ... Priority), the 15 building groups and Options. An
//   open group's tools go into a second column beside it, both the full height under the strip.
//   Their hover tooltips are removed: a touchscreen has no hover, and they stuck out of the
//   narrow columns. The bottom of the screen stays clear; the port's Esc and Dev keys sit in
//   the bottom-right corner (the profile's "touch_keys_corner"), under the rail.
// - Colony drawer: the well-being line, population, notifications (log height capped) and
//   pinned levers. View drawer: working hours, layers, districts, the overlay buttons and
//   the day clock. Both drawn larger.
// - The tool panel moves to the bottom edge, centred, its description folded to the title (a tap on
//   it unfolds it); rotate, flip, Rows and Place go into a rail on the right edge, as large
//   square icon buttons without their keyboard hints.
// A moved panel takes the style sheets of its old ancestors with it (the game attaches some
// to containers, e.g. the tool panel's to ToolPanel). Elements of ours that go into the game's
// ordered slots are added through UILayout, which looks up the order of every element in a
// slot when it adds one; panels the game adds to the slots later are swept into the drawers.
using System;
using System.Collections.Generic;
using Timberborn.SingletonSystem;
using Timberborn.ToolSystem;
using Timberborn.UILayoutSystem;
using UnityEngine;
using UnityEngine.UIElements;

namespace Recomp.Touchscreen
{
    public class MobileHud : IPostLoadableSingleton, IUpdatableSingleton
    {
        const float ColumnScale = 1.6f, TopBarScale = 1.45f, ColonyScale = 1.3f, ViewScale = 1.6f;
        const float ColumnWidth = 62f, ColumnGap = 6f;
        const float StripHeight = 80f, ColonyTabWidth = 130f, ViewTabWidth = 88f, Gap = 8f;
        const float SpeedWidth = 80f, SpeedHeight = 66f;
        const float BelowStrip = 150f;          // top of the View drawer, under the speed and date block
        const float RailButton = 76f, PlaceButton = 84f, RailIcon = 44f, RailGap = 6f;
        const float NotificationLogHeight = 90f;
        const float CheckSeconds = 0.5f;

        static readonly bool Phone = SystemInfo.deviceModel.StartsWith("iPhone", StringComparison.Ordinal);
        // Kept in the top-right block: the panels whose element names these are.
        static readonly string[] TopRightKept = { "SpeedControlPanel", "DatePanel", "WeatherPanel" };

        readonly EventBus _eventBus;
        readonly UILayout _uiLayout;
        VisualElement _gameUI, _absolute, _topLeft, _topRight, _topBar, _bottomSlot, _bar, _subSection;
        VisualElement _colonyDrawer, _viewDrawer, _rail, _placementPanel, _description;
        ScrollView _column, _toolsColumn;
        Button _colonyTab, _viewTab;
        Type _nineSliceButton, _nineSlice;
        Rect _safe;
        float _columnHeight = 300f;  // the columns' visible height, in their own (unscaled) units
        Vector2 _panelSize;
        float _nextCheck;
        bool _placing, _descriptionOpen;

        public MobileHud(EventBus eventBus, UILayout uiLayout)
        {
            _eventBus = eventBus;
            _uiLayout = uiLayout;
        }

        public void PostLoad()
        {
            if (!Phone) return;
            foreach (var doc in UnityEngine.Object.FindObjectsByType<UIDocument>(FindObjectsSortMode.None))
                if ((_gameUI = doc.rootVisualElement?.Q("GameUI")) != null) break;
            if (_gameUI == null)
            {
                Debug.Log("[Touchscreen] no GameUI: phone layout not applied");
                return;
            }
            _absolute = _gameUI.Q("Absolute-items");
            _topLeft = _gameUI.Q("Top-left");
            _topRight = _gameUI.Q("Top-right");
            _topBar = _gameUI.Q("Top-bar");
            _bottomSlot = _gameUI.Q("Bottom-bar");
            _bar = _bottomSlot?.Q("BottomBar");
            _nineSliceButton = _gameUI.Q("BatchControl")?.GetType();
            _nineSlice = _gameUI.Q("SpeedControlPanel")?.GetType();
            var done = new List<string>();
            Try("safe area", done, () =>
            {
                // Inset to the safe area by UpdateSingleton once the panel has a size.
                var s = _gameUI.style;
                s.position = Position.Absolute;
                s.left = s.right = s.top = s.bottom = 0f;
                s.width = s.height = StyleKeyword.Auto;
            });
            Try("placement rail", done, LayOutRail);     // before the tool panel moves: its style sheets
            Try("tool panel", done, LayOutToolPanel);
            Try("tool column", done, LayOutColumns);
            Try("goods counters", done, LayOutTopBar);
            Try("colony drawer", done, LayOutColony);
            Try("speed and view drawer", done, LayOutView);
            _eventBus.Register(this);
            Debug.Log("[Touchscreen] phone layout: " + string.Join(", ", done));
        }

        static void Try(string what, List<string> done, Action action)
        {
            try
            {
                action();
                done.Add(what);
            }
            catch (Exception e)
            {
                Debug.Log("[Touchscreen] phone layout: " + what + " failed: " + e);
            }
        }

        public void UpdateSingleton()
        {
            if (_gameUI == null) return;
            // A building being placed: the drawers have done their job.
            if (Placement.Active != _placing)
            {
                _placing = Placement.Active;
                if (_placing) CloseAll();
            }
            if (_description != null && !_descriptionOpen) FoldDescription(false);  // the game shows them again per tool
            if (_column != null)
            {
                // Shown with the game's bottom bar (hidden until the game starts, and by the batch
                // control window), and out of the Colony drawer's way.
                var shown = _bar.resolvedStyle.display != DisplayStyle.None && _bottomSlot.resolvedStyle.display != DisplayStyle.None
                            && (_colonyDrawer == null || _colonyDrawer.style.display == DisplayStyle.None);
                var display = shown ? DisplayStyle.Flex : DisplayStyle.None;
                if (_column.style.display != display) _column.style.display = display;
                LayOutToolsColumn(shown);
            }
            if (Time.unscaledTime < _nextCheck) return;
            _nextCheck = Time.unscaledTime + CheckSeconds;
            SweepColony();
            SweepView();
            KeepPlaceLast();
            var root = _gameUI.panel?.visualTree.layout ?? default;
            var safe = SafeArea();
            if (root.width <= 0f || (safe == _safe && root.size == _panelSize)) return;
            _safe = safe;
            _panelSize = root.size;
            // Screen pixels (origin bottom-left) to the panel's units.
            float kx = root.width / Screen.width, ky = root.height / Screen.height;
            var s = _gameUI.style;
            s.left = safe.xMin * kx;
            s.right = (Screen.width - safe.xMax) * kx;
            s.top = (Screen.height - safe.yMax) * ky;
            s.bottom = safe.yMin * ky;
            if (_column != null)
            {
                // From under the strip to the bottom of the safe area, in the columns' own (unscaled) units.
                var height = root.height - (Screen.height - safe.yMax) * ky - safe.yMin * ky;
                var visible = Mathf.Max(ColumnWidth, height - (StripHeight + Gap) - Gap) / ColumnScale;
                _column.style.height = _columnHeight = visible;
            }
            Debug.Log($"[Touchscreen] phone layout: safe area {safe} on a {Screen.width}x{Screen.height} screen, panel {root.width}x{root.height}");
        }

        // As Recomp.Layout.Area: iOS reports the safe area in the display's pixels, which after a
        // render scale can be larger than the screen.
        static Rect SafeArea()
        {
            var safe = Screen.safeArea;
            if (safe.xMax > Screen.width + 1 || safe.yMax > Screen.height + 1)
            {
                float w = Display.main.systemWidth, h = Display.main.systemHeight;
                if ((w > h) != (Screen.width > Screen.height)) (w, h) = (h, w);
                if (w <= 0 || h <= 0) return new Rect(0, 0, Screen.width, Screen.height);
                float sx = Screen.width / w, sy = Screen.height / h;
                safe = new Rect(safe.x * sx, safe.y * sy, safe.width * sx, safe.height * sy);
            }
            return Rect.MinMaxRect(Mathf.Max(0, safe.xMin), Mathf.Max(0, safe.yMin),
                                   Mathf.Min(Screen.width, safe.xMax), Mathf.Min(Screen.height, safe.yMax));
        }

        // The bar's buttons in a column on the left, the open group's tools in a second column.
        void LayOutColumns()
        {
            var main = _bar.Q("MainSection");
            _subSection = _bar.Q("SubSection");
            _column = Column("TouchscreenToolColumn", 0f);
            CarryStyles(main.Q("LeftSection"), _column);
            var bar = _column.style;
            bar.backgroundColor = new Color(68f / 255f, 58f / 255f, 34f / 255f, 0.8f);
            bar.borderTopLeftRadius = bar.borderTopRightRadius = bar.borderBottomLeftRadius = bar.borderBottomRightRadius = 4f;
            foreach (var name in new[] { "LeftSection", "MiddleSection", "RightSection" })
            {
                var section = main.Q(name);
                if (section == null) continue;
                foreach (var e in new List<VisualElement>(section.Children()))
                {
                    e.style.marginTop = e.style.marginBottom = 2f;
                    _column.Add(e);
                }
                var line = new VisualElement { pickingMode = PickingMode.Ignore };
                line.style.height = 2f;
                line.style.marginTop = line.style.marginBottom = 4f;
                line.style.backgroundColor = new Color(0.74f, 0.64f, 0.42f, 0.6f);
                _column.Add(line);
            }
            main.style.display = DisplayStyle.None;
            RemoveTooltips(_column);
            RemoveTooltips(_subSection);

            // The open group's tools (the game shows one group's row at a time), stacked.
            _toolsColumn = Column("TouchscreenToolsColumn", ColumnWidth * ColumnScale + ColumnGap);
            CarryStyles(_subSection, _toolsColumn);
            _subSection.style.flexDirection = FlexDirection.Column;
            foreach (var row in _subSection.Children())
            {
                row.style.flexDirection = FlexDirection.Column;
                row.style.flexWrap = Wrap.NoWrap;
                row.style.alignItems = Align.Center;
            }
            _toolsColumn.Add(_subSection);
        }

        // The tools column: shown while a group is open (the game shows that group's row), as tall as
        // its tools up to the left column's height, centred on it.
        void LayOutToolsColumn(bool shown)
        {
            var open = false;
            foreach (var row in _subSection.Children()) open |= row.resolvedStyle.display != DisplayStyle.None;
            var display = shown && open ? DisplayStyle.Flex : DisplayStyle.None;
            if (_toolsColumn.style.display != display) _toolsColumn.style.display = display;
            if (display == DisplayStyle.None) return;
            var content = _toolsColumn.contentContainer.layout.height;
            if (!(content > 0f)) return;
            var height = Mathf.Min(content, _columnHeight);
            var top = StripHeight + Gap + (_columnHeight - height) * ColumnScale / 2f;
            if (_toolsColumn.style.height != height) _toolsColumn.style.height = height;
            if (_toolsColumn.style.top != top) _toolsColumn.style.top = top;
        }

        // The game shows them on hover (BottomBar/ToolGroupButton.uxml, GrouplessToolButton.uxml).
        static void RemoveTooltips(VisualElement root)
        {
            foreach (var tooltip in root.Query(className: "tool-group__tooltip-wrapper").ToList())
                tooltip.RemoveFromHierarchy();
        }

        // A vertical list on the left edge under the strip, scaled from its top-left corner.
        ScrollView Column(string name, float left)
        {
            var column = new ScrollView(ScrollViewMode.Vertical) { name = name };
            column.verticalScrollerVisibility = ScrollerVisibility.Hidden;
            column.horizontalScrollerVisibility = ScrollerVisibility.Hidden;
            var s = column.style;
            s.position = Position.Absolute;
            s.left = left;
            s.top = StripHeight + Gap;
            s.width = ColumnWidth;
            s.height = 300f;  // until UpdateSingleton knows the screen
            column.contentContainer.style.alignItems = Align.Center;
            column.contentContainer.style.paddingTop = column.contentContainer.style.paddingBottom = 2f;
            Scale(column, ColumnScale, 0f, 0f);
            DragScroll.Attach(column, ColumnScale);
            _uiLayout.AddAbsoluteItem(column);
            return column;
        }

        [OnEvent]
        public void OnToolEntered(ToolEnteredEvent toolEnteredEvent)
        {
            // A tool picked: the drawers have done their job.
            CloseAll();
        }

        // The goods counters, larger, with their breakdowns closed (a tap on a counter opens its
        // breakdown, as in the game: TopBarCounterFactory.ToggleVisibility).
        void LayOutTopBar()
        {
            Scale(_topBar, TopBarScale, 0f, 0f);
            _topBar.Query<Button>("ExtensionToggler").ForEach(toggler =>
            {
                var counter = toggler.parent;
                var items = counter.Q("CounterItems");
                if (items == null || items.style.display == DisplayStyle.None) return;
                toggler.EnableInClassList("extension-clamp--hidden", true);
                var background = counter.Q("Background");
                if (background != null) background.style.display = DisplayStyle.None;
                items.style.display = DisplayStyle.None;
            });
        }

        // A Colony tab at the start of the strip; the whole top-left column goes into the drawer
        // under it. Both live in the slot, which the batch control window hides.
        void LayOutColony()
        {
            _colonyDrawer = Drawer("TouchscreenColonyDrawer");
            _colonyDrawer.style.left = 0f;
            _colonyDrawer.style.top = StripHeight + Gap;
            Scale(_colonyDrawer, ColonyScale, 0f, 0f);
            _colonyTab = Tab("TouchscreenColony", "UI/Images/Game/ico-beavers", "Colony", ColonyTabWidth, () => Toggle(_colonyDrawer, _colonyTab));
            _topLeft.style.flexDirection = FlexDirection.Row;
            _topLeft.style.alignItems = Align.FlexStart;
            _uiLayout.AddTopLeft(_colonyTab, int.MinValue);
            _uiLayout.AddTopLeft(_colonyDrawer, int.MaxValue);
            SweepColony();
        }

        void SweepColony()
        {
            if (_colonyDrawer == null) return;
            var moved = new List<VisualElement>();
            foreach (var child in _topLeft.Children())
                if (child != _colonyTab && child != _colonyDrawer) moved.Add(child);
            foreach (var e in moved)
            {
                _colonyDrawer.Add(e);
                var log = e.Q<ScrollView>("Notifications");
                if (log != null) log.style.height = log.style.maxHeight = NotificationLogHeight;
            }
        }

        // Speed (larger), date and weather stay in the block, which moves left of a View tab at the
        // strip's right end; the rest of the block, the clock too, goes into the drawer under the tab.
        void LayOutView()
        {
            var speed = _topRight.Q("SpeedControlPanel");
            if (speed != null)
            {
                speed.style.paddingRight = 4f;
                speed.Query<Button>().ForEach(b =>
                {
                    b.style.width = SpeedWidth;
                    b.style.height = SpeedHeight;
                    b.style.justifyContent = Justify.Center;
                    b.style.alignItems = Align.Center;
                });
            }
            _topRight.style.right = ViewTabWidth + Gap;
            _topRight.style.height = StyleKeyword.Auto;
            _topRight.style.flexWrap = Wrap.NoWrap;
            _topRight.style.alignItems = Align.FlexEnd;

            _viewDrawer = Drawer("TouchscreenViewDrawer");
            _viewDrawer.style.right = 0f;
            _viewDrawer.style.top = BelowStrip;
            _viewDrawer.style.alignItems = Align.FlexEnd;
            Scale(_viewDrawer, ViewScale, 100f, 0f);
            _viewTab = Tab("TouchscreenView", "UI/Images/Game/ico-eye", "View", ViewTabWidth, () => Toggle(_viewDrawer, _viewTab));
            _viewTab.style.position = Position.Absolute;
            _viewTab.style.right = 0f;
            _viewTab.style.top = 0f;
            _uiLayout.AddAbsoluteItem(_viewTab);
            _uiLayout.AddAbsoluteItem(_viewDrawer);
            SweepView();
        }

        void SweepView()
        {
            if (_viewDrawer == null) return;
            var moved = new List<VisualElement>();
            foreach (var child in _topRight.Children())
            {
                var kept = false;
                foreach (var name in TopRightKept) kept |= child.name == name || child.Q(name) != null;
                if (!kept) moved.Add(child);
            }
            foreach (var e in moved)
            {
                _viewDrawer.Add(e);
                if (e.name == "Clock" || e.Q("Clock") != null)
                {
                    // Absolute in the block (over the date), in line in the drawer.
                    e.style.position = Position.Relative;
                    e.style.top = e.style.right = StyleKeyword.Auto;
                    e.style.marginTop = 4f;
                }
            }
        }

        // The placement panel (rotate, flip and the Touchscreen's Place and Rows) on the right edge:
        // square icon buttons, Place last and largest. The game shows and hides the panel itself.
        void LayOutRail()
        {
            _placementPanel = _gameUI.Q("BlockObjectPlacementPanel");
            if (_placementPanel == null) return;
            _rail = new VisualElement { name = "TouchscreenRail", pickingMode = PickingMode.Ignore };
            CarryStyles(_placementPanel, _rail);
            var s = _rail.style;
            s.position = Position.Absolute;
            s.right = 0f;
            s.top = StripHeight + Gap;  // under the View tab, over the Esc and Dev keys
            s.alignItems = Align.FlexEnd;
            _placementPanel.style.flexDirection = FlexDirection.Column;
            _placementPanel.style.alignItems = Align.FlexEnd;
            _rail.Add(_placementPanel);
            _uiLayout.AddAbsoluteItem(_rail);
            KeepPlaceLast();
        }

        // Also styles the Touchscreen's own buttons, which PlacementButtons adds on the first placement.
        void KeepPlaceLast()
        {
            if (_placementPanel == null) return;
            foreach (var b in _placementPanel.Query<Button>().ToList())
            {
                var size = b.name == "TouchscreenPlace" ? PlaceButton : RailButton;
                if (b.style.width == size) continue;
                b.style.width = b.style.height = size;
                b.style.marginLeft = b.style.marginRight = 0f;
                b.style.marginBottom = RailGap;
                b.style.justifyContent = Justify.Center;
                b.style.alignItems = Align.Center;
                b.Query<Label>().ForEach(l => l.style.display = DisplayStyle.None);
                foreach (var child in b.Children())
                    if (!(child is Label))
                    {
                        var c = child.style;
                        c.width = c.height = c.minWidth = c.minHeight = c.maxWidth = c.maxHeight = RailIcon;
                        c.marginLeft = c.marginRight = 0f;
                    }
            }
            var place = _placementPanel.Q("TouchscreenPlace");
            if (place != null && place.parent.IndexOf(place) != place.parent.childCount - 1) place.BringToFront();
        }

        // The tool panel (the tool's description, warnings) at the bottom edge, centred, folded to
        // its title until tapped.
        void LayOutToolPanel()
        {
            var toolPanel = _bottomSlot.Q("ToolPanel");
            if (toolPanel == null) return;
            var holder = new VisualElement { name = "TouchscreenToolPanel", pickingMode = PickingMode.Ignore };
            var s = holder.style;
            s.position = Position.Absolute;
            s.left = s.right = 0f;
            s.bottom = Gap;  // between the tool column and the Esc and Dev keys; unfolds upwards
            s.alignItems = Align.Center;
            CarryStyles(toolPanel, holder);
            holder.Add(toolPanel);
            _uiLayout.AddAbsoluteItem(holder);
            _description = toolPanel.Q("DescriptionPanel");
            if (_description == null) return;
            _description.RegisterCallback<ClickEvent>(_ => FoldDescription(!_descriptionOpen));
            FoldDescription(false);
        }

        void FoldDescription(bool open)
        {
            _descriptionOpen = open;
            var shown = open ? DisplayStyle.Flex : DisplayStyle.None;
            var internalSections = _description.Q("InternalSections");
            if (internalSections != null) internalSections.style.display = shown;
            var external = _description.parent?.Q("ExternalSections");
            if (external != null) external.style.display = shown;
        }

        // The style sheets the element got from its ancestors, up to the game's HUD root.
        void CarryStyles(VisualElement element, VisualElement to)
        {
            for (var e = element.parent; e != null && e != _gameUI; e = e.parent)
                for (int i = 0; i < e.styleSheets.count; i++)
                    to.styleSheets.Add(e.styleSheets[i]);
        }

        static void Scale(VisualElement e, float scale, float originX, float originY)
        {
            e.style.scale = new Scale(new Vector3(scale, scale, 1f));
            e.style.transformOrigin = new TransformOrigin(Length.Percent(originX), Length.Percent(originY), 0f);
        }

        VisualElement Drawer(string name)
        {
            var drawer = Create<VisualElement>(_nineSlice, "square-large--green");
            drawer.name = name;
            var s = drawer.style;
            s.position = Position.Absolute;
            s.paddingLeft = s.paddingRight = s.paddingTop = s.paddingBottom = 8f;
            s.display = DisplayStyle.None;
            return drawer;
        }

        Button Tab(string name, string icon, string caption, float width, Action clicked)
        {
            var tab = Create<Button>(_nineSliceButton, "button-game");
            tab.name = name;
            tab.clicked += clicked;
            var s = tab.style;
            s.width = width;
            s.height = StripHeight;
            s.marginTop = 0f;
            s.marginLeft = s.marginRight = Gap / 2f;
            s.flexDirection = FlexDirection.Column;
            s.alignItems = Align.Center;
            s.justifyContent = Justify.Center;
            var image = new VisualElement { pickingMode = PickingMode.Ignore };
            image.style.width = image.style.height = 36f;
            image.style.backgroundImage = PlacementButtons.Image(icon);
            tab.Add(image);
            var label = new Label(caption) { pickingMode = PickingMode.Ignore };
            label.AddToClassList("game-text-normal");
            label.AddToClassList("text--yellow");
            tab.Add(label);
            return tab;
        }

        // The game's nine-slice element types (internal to the game) give its frames; plain ones otherwise.
        static T Create<T>(Type type, string cls) where T : VisualElement, new()
        {
            T e = null;
            if (type != null && typeof(T).IsAssignableFrom(type))
            {
                try { e = (T)Activator.CreateInstance(type); }
                catch (Exception ex) { Debug.Log("[Touchscreen] " + type.Name + ": " + ex.Message); }
            }
            if (e == null)
            {
                e = new T();
                e.style.backgroundColor = new Color(0.1f, 0.16f, 0.14f, 0.95f);
            }
            e.AddToClassList(cls);
            return e;
        }

        void Toggle(VisualElement drawer, Button tab)
        {
            var show = drawer.style.display == DisplayStyle.None;
            CloseAll();
            Open(drawer, tab, show);
        }

        void CloseAll()
        {
            Open(_colonyDrawer, _colonyTab, false);
            Open(_viewDrawer, _viewTab, false);
        }

        static void Open(VisualElement drawer, Button tab, bool show)
        {
            if (drawer == null) return;
            drawer.style.display = show ? DisplayStyle.Flex : DisplayStyle.None;
            tab?.EnableInClassList("button--active", show);
        }
    }
}
