// The game's HUD laid out for an iPhone's short screen (iPhone only; an iPad keeps the
// game's own layout). Every HUD panel sits in one of the named slots of the game's
// Views/Common/GameUI.uxml (Top-left, Top-right, Top-bar, Bottom-bar, ...); this moves
// whole panels between containers and leaves the game's references to them intact, so the
// game goes on updating and showing them as usual. Sizes are in the panel's units: on an
// iPhone 17 at the game's largest UI scale one unit is about 0.54 pt, so Apple's 44 pt
// touch target is about 80 units.
// - The HUD keeps inside the safe area: clear of the Dynamic Island and the home indicator.
//   On the side away from the island it keeps only a third of the safe area's margin (that
//   margin is there for the island's side; the other side has just the rounded corners). The
//   port's Esc and Dev keys sit in the island's strip (the profile's "touch_keys_corner": "island").
// - Top strip, 80 units tall: a Colony tab, the goods counters drawn 1.45 times larger with
//   their breakdowns closed, and a View tab at the right end, as tall as the column left of it
//   and reaching the screen's edge. That column: the speed buttons (scaled to the date's
//   width), date and weather, with the day clock left of it, as tall as the column.
// - The bottom bar becomes a column on the left edge, drawn 1.6 times larger and scrolled by
//   dragging: the general tools (Select ... Priority), the 15 building groups and Options. An
//   open group's tools go into a second column beside it, both the full height under the strip.
//   Their hover tooltips are removed: a touchscreen has no hover, and they stuck out of the
//   narrow columns.
// - Colony drawer: the well-being line, population, notifications (log height capped) and
//   pinned levers. View drawer: the overlay buttons centred at the top, working hours and the
//   visible levels scaled to the district switcher's width, and the switcher last (its list
//   opens under it and the drawer grows), a little taller, its arrows as big as working hours'
//   -/+. Both drawers drawn larger.
// - Rotate, flip, Rows and Place go into a rail on the right edge, as large square icon buttons
//   of one size without their keyboard hints, and the building's cost (the green box) under
//   them. The tool's description box is not shown; the rest of the tool panel (warnings) moves
//   to the bottom edge, centred.
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
        const float ColumnScale = 1.6f, TopBarScale = 1.45f, ColonyScale = 1.3f, ViewScale = 1.3f;
        const float ColumnWidth = 62f, ColumnGap = 6f;
        const float StripHeight = 80f, ColonyTabWidth = 130f, ViewTabWidth = 88f, Gap = 8f;
        const float OverlayButtonsScale = 1.7f;
        const float BelowStrip = 150f;          // top of the View drawer until the block above it is laid out
        const float RailButton = 76f, RailIcon = 44f, RailGap = 6f;
        const float AwayFromIsland = 1f / 3f;  // the share of the safe area's side margin kept away from the island
        const float NotificationLogHeight = 90f;
        const float CheckSeconds = 0.5f;

        static readonly bool Phone = SystemInfo.deviceModel.StartsWith("iPhone", StringComparison.Ordinal);
        // Kept in the top-right block: the panels whose element names these are.
        static readonly string[] TopRightKept = { "SpeedControlPanel", "DatePanel", "WeatherPanel" };

        readonly EventBus _eventBus;
        readonly UILayout _uiLayout;
        VisualElement _gameUI, _absolute, _topLeft, _topRight, _topBar, _bottomSlot, _bar, _subSection;
        VisualElement _colonyDrawer, _viewDrawer, _rail, _placementPanel, _toolPanel;
        VisualElement _timeBlock, _timeColumn, _clockHolder, _clock, _speedRow, _date;
        readonly HashSet<VisualElement> _descriptions = new HashSet<VisualElement>();  // the game makes one per tool
        readonly Dictionary<VisualElement, VisualElement> _costs = new Dictionary<VisualElement, VisualElement>();  // cost box -> its description's row
        VisualElement _costHolder;
        ScrollView _column, _toolsColumn;
        Button _colonyTab, _viewTab;
        Type _nineSliceButton, _nineSlice;
        Rect _safe;
        float _rightInset;               // the HUD's right margin, in panel units (the View tab reaches past it)
        float _tabFont, _districtFont;   // the game's own font sizes, before they are scaled
        float _levelsWidth, _levelBox, _levelFont;  // the levels bar's own width, level box height and font size
        readonly Dictionary<VisualElement, VisualElement> _holders = new Dictionary<VisualElement, VisualElement>();  // panel -> FitInHolder's holder
        readonly HashSet<VisualElement> _held = new HashSet<VisualElement>();  // the holders
        string _loggedView;
        ScreenOrientation _orientation;
        float _columnHeight = 300f;  // the columns' visible height, in their own (unscaled) units
        Vector2 _panelSize;
        float _nextCheck;
        bool _placing;

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
            ArrangeDescriptions();
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
            if (_timeBlock != null)
            {
                // Shown with the game's top-right slot (the batch control window hides it).
                var display = _topRight.resolvedStyle.display;
                if (_timeBlock.style.display != display) _timeBlock.style.display = display;
            }
            if (Time.unscaledTime < _nextCheck) return;
            _nextCheck = Time.unscaledTime + CheckSeconds;
            SweepColony();
            SweepView();
            ArrangeView();
            KeepPlaceLast();
            var root = _gameUI.panel?.visualTree.layout ?? default;
            var safe = SafeArea();
            if (root.width <= 0f || (safe == _safe && root.size == _panelSize && Screen.orientation == _orientation)) return;
            _safe = safe;
            _panelSize = root.size;
            _orientation = Screen.orientation;
            // Screen pixels (origin bottom-left) to the panel's units.
            float kx = root.width / Screen.width, ky = root.height / Screen.height;
            var s = _gameUI.style;
            // Sideways, the island is on the left in LandscapeLeft (turned counter-clockwise), else the right.
            float left = safe.xMin, right = Screen.width - safe.xMax;
            if (_orientation == ScreenOrientation.LandscapeLeft) right *= AwayFromIsland;
            else if (_orientation == ScreenOrientation.LandscapeRight) left *= AwayFromIsland;
            s.left = left * kx;
            s.right = _rightInset = right * kx;
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

        // Left of a View tab at the strip's right end: the speed buttons, date and weather in a
        // column, the speed buttons scaled to the date's width, and the game's day clock left of the
        // column, as tall as it. The rest of the top-right block goes into the drawer under the tab:
        // the overlay buttons centred at the top and larger, the district switcher under them, then
        // working hours and the visible levels scaled to the switcher's width.
        void LayOutView()
        {
            _timeBlock = new VisualElement { name = "TouchscreenTimeBlock", pickingMode = PickingMode.Ignore };
            // The game's panels arrive later (SweepView): the style sheets of the block and its ancestors.
            CarryStyles(_topRight, _timeBlock);
            for (int i = 0; i < _topRight.styleSheets.count; i++) _timeBlock.styleSheets.Add(_topRight.styleSheets[i]);
            var s = _timeBlock.style;
            s.position = Position.Absolute;
            s.right = ViewTabWidth + Gap;
            s.top = 0f;
            s.flexDirection = FlexDirection.Row;
            s.alignItems = Align.FlexStart;
            _clockHolder = new VisualElement { name = "TouchscreenClock", pickingMode = PickingMode.Ignore };
            _clockHolder.style.marginRight = Gap / 2f;
            _clockHolder.style.marginTop = 4f;
            _timeColumn = new VisualElement { pickingMode = PickingMode.Ignore };
            _timeColumn.style.alignItems = Align.Center;
            _timeBlock.Add(_clockHolder);
            _timeBlock.Add(_timeColumn);
            _uiLayout.AddAbsoluteItem(_timeBlock);

            _viewDrawer = Drawer("TouchscreenViewDrawer");
            // Laid out while closed (hidden, not removed), so ArrangeView has its sizes before it
            // first opens: closed by display, it showed its bars small and resized them on opening.
            _viewDrawer.style.display = DisplayStyle.Flex;
            _viewDrawer.visible = false;
            _viewDrawer.style.right = 0f;
            _viewDrawer.style.top = BelowStrip;
            _viewDrawer.style.alignItems = Align.Center;
            Scale(_viewDrawer, ViewScale, 100f, 0f);
            _viewTab = Tab("TouchscreenView", "UI/Images/Game/ico-eye", "View", ViewTabWidth, () => Toggle(_viewDrawer, _viewTab));
            _viewTab.style.position = Position.Absolute;
            _viewTab.style.right = 0f;
            _viewTab.style.top = 0f;
            _uiLayout.AddAbsoluteItem(_viewTab);
            _uiLayout.AddAbsoluteItem(_viewDrawer);
            SweepView();
        }

        // The place of a top-right panel in the column (TopRightKept), or -1.
        static int KeptIndex(VisualElement e)
        {
            for (int i = 0; i < TopRightKept.Length; i++)
                if (e.name == TopRightKept[i] || e.Q(TopRightKept[i]) != null) return i;
            return -1;
        }

        // A speed, date or weather panel, as the game adds it (after this layout), into the column in
        // that order.
        void AddToColumn(VisualElement e, int index)
        {
            e.style.marginLeft = e.style.marginRight = 0f;
            e.style.alignSelf = Align.Center;  // the game's style puts some at the end
            var at = 0;
            foreach (var child in _timeColumn.Children())
                if (KeptIndex(child) < index) at++;
            _timeColumn.Insert(at, e);
            var speed = e.name == "SpeedControlPanel" ? e : e.Q("SpeedControlPanel");
            if (speed != null)
            {
                // The game pads the speed buttons' right for the clock, which overlapped the block:
                // the buttons and their frame alone, to be scaled to the date's width.
                e.style.paddingRight = 0f;
                e.style.minWidth = 0f;
                e.style.height = StyleKeyword.Auto;
                speed.style.paddingRight = speed.style.paddingLeft = 4f;
                speed.style.minWidth = 0f;
                speed.style.flexGrow = 0f;
                _speedRow = e;
            }
            var date = e.name == "DatePanel" ? e : e.Q("DatePanel");
            if (date != null) _date = date;
            Debug.Log("[Touchscreen] phone layout: " + TopRightKept[index] + " into the time column");
        }

        // What the game adds to the top-right block: speed, date and weather into the column, the
        // clock beside it, the rest into the drawer.
        void SweepView()
        {
            if (_viewDrawer == null) return;
            var moved = new List<VisualElement>(_topRight.Children());
            foreach (var e in moved)
            {
                var kept = KeptIndex(e);
                if (kept >= 0) AddToColumn(e, kept);
                else if (_clock == null && (e.name == "Clock" || e.Q("Clock") != null))
                {
                    // Absolute over the block's top-right corner in the game; at the holder's corner here.
                    _clock = e;
                    var c = e.style;
                    c.position = Position.Absolute;
                    c.left = c.top = 0f;
                    c.right = c.bottom = StyleKeyword.Auto;
                    c.marginLeft = c.marginRight = c.marginTop = c.marginBottom = 0f;
                    _clockHolder.Add(e);
                }
                else _viewDrawer.Add(e);
            }
        }

        // Each check, once laid out: sizes that depend on the game's own (the date's width, the
        // column's height, the switcher's width), and the drawer's order.
        void ArrangeView()
        {
            if (_timeColumn == null) return;
            if (_speedRow != null && _date != null) FitWidth(_speedRow, _date.layout.width);
            var height = _timeColumn.layout.height;
            if (_clock != null && height > 0f)
            {
                var size = Mathf.Max(_clock.layout.width, _clock.layout.height);
                if (size > 0f)
                {
                    _clockHolder.style.width = _clockHolder.style.height = height - 4f;
                    Scale(_clock, (height - 4f) / size, 0f, 0f);
                }
            }
            if (_timeBlock.layout.height > 0f) _viewDrawer.style.top = _timeBlock.layout.yMax + Gap;

            // The drawer's children, through the holders FitInHolder puts some of them in.
            VisualElement district = null, hours = null, levels = null;
            var order = new List<VisualElement>();
            var others = new List<VisualElement>();
            foreach (var child in _viewDrawer.Children())
            {
                var panel = _held.Contains(child) && child.childCount > 0 ? child[0] : child;
                if (panel.name == "DistrictPanel" || panel.Q("DistrictPanel") != null) district = panel;
                else if (panel.Q("WorkingHours") != null) hours = panel;
                else if (panel.name == "LevelVisibilityPanel" || panel.Q("LevelVisibilityPanel") != null) levels = panel;
                else others.Add(panel);
            }
            var width = district?.Q("DistrictHeader")?.layout.width ?? 0f;
            foreach (var other in others) FitInHolder(other, other, OverlayButtonsScale);
            var hoursBar = hours?.Q("WorkingHours");
            var hoursScale = hoursBar != null && hoursBar.layout.width > 0f && width > 0f ? width / hoursBar.layout.width : 1f;
            if (hoursBar != null) FitInHolder(hours, hoursBar, hoursScale);
            if (levels != null)
            {
                // Its reset button keeps its room while hidden (disabled) and put the bar off
                // centre; ∞ via the arrows does the same.
                var reset = levels.Q("Reset");
                if (reset != null && reset.style.display != DisplayStyle.None) reset.style.display = DisplayStyle.None;
                var levelsBar = levels.Q("Content") ?? levels;
                if (levelsBar.layout.width > 0f && width > 0f)
                {
                    var levelsScale = width / levelsBar.layout.width;
                    var minus = hoursBar?.Q("Minus");
                    if (minus != null && minus.layout.width > 0f) ArrangeLevels(levelsBar, levelsScale, minus.layout.width * hoursScale);
                    FitInHolder(levels, levelsBar, levelsScale);
                }
            }
            if (district != null)
            {
                district.style.alignSelf = Align.Center;
                district.style.marginLeft = district.style.marginRight = 0f;
            }
            foreach (var panel in others) order.Add(Slot(panel));
            foreach (var panel in new[] { hours, levels, district })
                if (panel != null) order.Add(Slot(panel));
            for (int i = 0; i < order.Count; i++)
                if (_viewDrawer.IndexOf(order[i]) != i) _viewDrawer.Insert(i, order[i]);
            if (district != null) ArrangeDistrict(district, hoursBar, hoursScale);
            ArrangeViewTab();
            LogView();
        }

        // The View tab as tall as the speed/date/weather column, level with it, reaching the
        // screen's edge; its icon and label grow with it. The block moves left of it and the
        // rail starts under it.
        void ArrangeViewTab()
        {
            if (_timeColumn.childCount == 0) return;
            var first = _timeColumn[0];
            var last = _timeColumn[_timeColumn.childCount - 1];
            var y = _timeBlock.layout.y + _timeColumn.layout.y;
            var top = y + first.layout.y;
            var height = y + last.layout.yMax - top;
            if (!(height > 0f)) return;
            var k = height / StripHeight;
            var t = _viewTab.style;
            if (t.top == top && t.height == height && t.right == -_rightInset) return;
            t.top = top;
            t.height = height;
            t.right = -_rightInset;
            t.width = ViewTabWidth * k + _rightInset;
            _timeBlock.style.right = ViewTabWidth * k + Gap;
            foreach (var child in _viewTab.Children())
            {
                if (child is Label label)
                {
                    if (_tabFont <= 0f) _tabFont = label.resolvedStyle.fontSize;
                    if (_tabFont > 0f) label.style.fontSize = _tabFont * k;
                }
                else child.style.width = child.style.height = 36f * k;
            }
            if (_rail != null) _rail.style.top = top + height + Gap;
        }

        // Global view, at the drawer's bottom, keeps its width but grows a little: its arrows as big
        // as working hours' -/+ once that bar is scaled to this width, its name and icon larger.
        // Its district list (an absolute panel under it in the game) joins the layout, so the
        // drawer grows when the list opens.
        void ArrangeDistrict(VisualElement district, VisualElement hours, float k)
        {
            var minus = hours?.Q("Minus");
            var arrow = minus != null && minus.layout.width > 0f ? minus.layout.width * k : 24f;
            foreach (var name in new[] { "PreviousDistrict", "NextDistrict" })
            {
                var b = district.Q(name);
                if (b == null || b.style.width == arrow) continue;
                b.style.width = b.style.height = b.style.minWidth = b.style.minHeight = b.style.maxWidth = b.style.maxHeight = arrow;
            }
            var header = district.Q("DistrictHeader");
            if (header != null && header.style.height != arrow + 10f) header.style.height = header.style.minHeight = arrow + 10f;
            var title = district.Q("DistrictName");
            if (title != null)
            {
                if (_districtFont <= 0f) _districtFont = title.resolvedStyle.fontSize;
                var size = _districtFont * 1.2f;
                if (_districtFont > 0f && title.style.fontSize != size)
                {
                    title.style.fontSize = size;
                    title.style.width = StyleKeyword.Auto;
                    title.style.maxWidth = StyleKeyword.None;
                    title.style.flexGrow = title.style.flexShrink = 1f;
                    title.style.height = arrow;
                }
            }
            var icon = header?.Q(className: "district-panel__icon");
            if (icon != null) icon.style.minWidth = icon.style.minHeight = icon.style.maxWidth = icon.style.maxHeight = 31f;
            var list = district.Q("Background");
            if (list != null && list.style.position != Position.Relative)
            {
                list.style.position = Position.Relative;
                list.style.top = list.style.bottom = list.style.left = list.style.right = StyleKeyword.Auto;
                list.style.paddingTop = 0f;
                list.style.alignSelf = Align.Stretch;
                // Its open/close arrow hangs below the list in the game (absolute): in the flow at
                // its end, so it sits against Global view's box when the list is closed.
                var arrowToggle = list.Q("ExtensionToggler");
                if (arrowToggle != null)
                {
                    var a = arrowToggle.style;
                    a.position = Position.Relative;
                    a.top = a.bottom = a.left = a.right = StyleKeyword.Auto;
                    a.marginTop = a.marginBottom = 0f;
                    a.alignSelf = Align.Center;
                }
            }
        }

        // Where each piece ended up, on screen (panel units, after scaling), when that changes: the
        // log shows the layout without a screenshot.
        void LogView()
        {
            var parts = new List<string>();
            void Add(string what, VisualElement e)
            {
                if (e == null) { parts.Add(what + " missing"); return; }
                var r = e.worldBound;
                parts.Add($"{what} [{r.xMin:0},{r.yMin:0} {r.width:0}x{r.height:0}" + (e.resolvedStyle.display == DisplayStyle.None ? " hidden" : "") + "]");
            }
            Add("time block", _timeBlock);
            Add("clock", _clock);
            Add("speed", _speedRow);
            Add("date", _date);
            Add("weather", _timeColumn.Q("WeatherPanel"));
            Add("column", _timeColumn);
            Add("view tab", _viewTab);
            Add("drawer", _viewDrawer);
            foreach (var child in _viewDrawer.Children())
                Add("drawer:" + (string.IsNullOrEmpty(child.name) ? child.GetType().Name + "." + string.Join(".", child.GetClasses()) : child.name), child);
            var line = string.Join("; ", parts);
            if (line == _loggedView) return;
            _loggedView = line;
            Debug.Log("[Touchscreen] view layout: " + line);
        }

        // The levels bar: its up/down arrows as big on screen as Global view's (arrow, in the
        // drawer's units; k is the bar's scale), the bar as tall as they need, its icon and the
        // level box (∞ or a number) grown to that height, the box narrower so the bar keeps the
        // width it is scaled by.
        void ArrangeLevels(VisualElement bar, float k, float arrow)
        {
            var wrapper = bar.Q("LevelButtonWrapper");
            var label = bar.Q<Label>("Level");
            if (_levelsWidth <= 0f)
            {
                if (!(bar.layout.width > 0f) || wrapper == null || !(wrapper.layout.height > 0f)) return;
                _levelsWidth = bar.layout.width;
                _levelBox = wrapper.layout.height;
                _levelFont = label?.resolvedStyle.fontSize ?? 0f;
                bar.style.width = _levelsWidth;
                bar.style.flexGrow = 0f;
            }
            var size = arrow / k;
            if (bar.style.height == size + 4f) return;
            bar.style.height = size + 4f;
            foreach (var name in new[] { "Up", "Down" })
            {
                var b = bar.Q(name);
                if (b != null) b.style.width = b.style.height = b.style.minWidth = b.style.minHeight = b.style.maxWidth = b.style.maxHeight = size;
            }
            var arrows = bar.Q("ButtonsWrapper");
            if (arrows != null)
            {
                arrows.style.width = arrows.style.minWidth = StyleKeyword.Auto;
                arrows.style.flexShrink = 0f;
            }
            var icon = bar.Q("LevelIcon");
            if (icon != null) icon.style.width = icon.style.height = icon.style.minWidth = icon.style.minHeight = icon.style.maxWidth = icon.style.maxHeight = size;
            if (wrapper != null)
            {
                var w = wrapper.style;
                w.height = size;
                w.width = StyleKeyword.Auto;
                w.minWidth = 0f;
                w.flexGrow = w.flexShrink = 1f;
                w.marginLeft = w.marginRight = 4f;
            }
            var button = bar.Q("LevelButton");
            if (button != null) button.style.width = button.style.height = Length.Percent(100);
            if (label != null && _levelFont > 0f && _levelBox > 0f) label.style.fontSize = _levelFont * size / _levelBox;
        }

        // What takes a panel's place among the drawer's children: its holder, or itself.
        VisualElement Slot(VisualElement panel) => _holders.TryGetValue(panel, out var holder) ? holder : panel;

        // A game panel drawn k times larger inside a holder of ours that is exactly the size of its
        // visible part once scaled, in the panel's place: the drawer lays out and centres the
        // holder, so the game's margins, paddings and alignments (some bars are padded on one side
        // and aligned to the end) and the scale cannot throw it off.
        void FitInHolder(VisualElement panel, VisualElement visible, float k)
        {
            if (!_holders.TryGetValue(panel, out var holder))
            {
                holder = new VisualElement { pickingMode = PickingMode.Ignore };
                holder.style.flexShrink = 0f;
                holder.style.alignSelf = Align.Center;
                holder.style.marginBottom = 4f;
                var parent = panel.parent;
                parent.Insert(parent.IndexOf(panel), holder);
                holder.Add(panel);
                var p = panel.style;
                p.position = Position.Absolute;
                p.marginLeft = p.marginRight = p.marginTop = p.marginBottom = 0f;
                _holders[panel] = holder;
                _held.Add(holder);
            }
            float w = visible.layout.width, h = visible.layout.height;
            if (!(w > 0f) || !(h > 0f) || !(k > 0f)) return;
            var offset = Vector2.zero;
            for (var e = visible; e != null && e != panel; e = e.parent) offset += e.layout.position;
            if (panel.style.scale.value.value.x != k) Scale(panel, k, 0f, 0f);
            if (panel.style.left != -offset.x * k) panel.style.left = -offset.x * k;
            if (panel.style.top != -offset.y * k) panel.style.top = -offset.y * k;
            if (holder.style.width != w * k) holder.style.width = w * k;
            if (holder.style.height != h * k) holder.style.height = h * k;
        }

        // Scaled about its top centre to a width (its parent centres it), leaving room under it for
        // the height it gains.
        static void FitWidth(VisualElement e, float width)
        {
            var w = e.layout.width;
            if (w > 0f && width > 0f) ScaleCentred(e, width / w);
        }

        static void ScaleCentred(VisualElement e, float k)
        {
            if (e.style.scale.value.value.x == k) return;
            Scale(e, k, 50f, 0f);
            e.style.marginBottom = Mathf.Max(0f, e.layout.height * (k - 1f)) + 4f;
        }

        // The placement panel (rotate, flip and the Touchscreen's Place and Rows) on the right edge:
        // square icon buttons of one size, Place last. The game shows and hides the panel itself.
        void LayOutRail()
        {
            _placementPanel = _gameUI.Q("BlockObjectPlacementPanel");
            if (_placementPanel == null) return;
            _rail = new VisualElement { name = "TouchscreenRail", pickingMode = PickingMode.Ignore };
            CarryStyles(_placementPanel, _rail);
            var s = _rail.style;
            s.position = Position.Absolute;
            s.right = 0f;
            s.top = StripHeight + Gap;  // under the View tab (ArrangeViewTab moves it once that is sized)
            s.alignItems = Align.FlexEnd;
            _placementPanel.style.flexDirection = FlexDirection.Column;
            _placementPanel.style.alignItems = Align.FlexEnd;
            _rail.Add(_placementPanel);
            _costHolder = new VisualElement { name = "TouchscreenCost", pickingMode = PickingMode.Ignore };
            _costHolder.style.alignItems = Align.FlexEnd;
            _rail.Add(_costHolder);
            _uiLayout.AddAbsoluteItem(_rail);
            KeepPlaceLast();
        }

        // Also styles the Touchscreen's own buttons, which PlacementButtons adds on the first placement.
        void KeepPlaceLast()
        {
            if (_placementPanel == null) return;
            foreach (var b in _placementPanel.Query<Button>().ToList())
            {
                if (b.style.width == RailButton) continue;
                b.style.width = b.style.height = b.style.minWidth = b.style.minHeight = b.style.maxWidth = b.style.maxHeight = RailButton;
                b.style.paddingLeft = b.style.paddingRight = b.style.paddingTop = b.style.paddingBottom = 0f;
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

        // The tool panel (the tool's description, warnings) at the bottom edge, centred; its
        // description box hidden and the cost moved to the rail (ArrangeDescriptions).
        void LayOutToolPanel()
        {
            var toolPanel = _bottomSlot.Q("ToolPanel");
            if (toolPanel == null) return;
            var holder = new VisualElement { name = "TouchscreenToolPanel", pickingMode = PickingMode.Ignore };
            var s = holder.style;
            s.position = Position.Absolute;
            s.left = s.right = 0f;
            s.bottom = Gap;  // between the tool column and the rail
            s.alignItems = Align.Center;
            CarryStyles(toolPanel, holder);
            holder.Add(toolPanel);
            _uiLayout.AddAbsoluteItem(holder);
            _toolPanel = toolPanel;
            ArrangeDescriptions();
        }

        // Every frame, as the game makes a description panel per tool (Common/ToolPanel/
        // DescriptionPanel.uxml: the DescriptionPanel box, then ExternalSections beside it, which
        // holds the building's cost): the box hidden, the cost moved under the rail's buttons and
        // shown while its description is (the game adds and removes them with the tool).
        void ArrangeDescriptions()
        {
            if (_toolPanel == null) return;
            _toolPanel.Query("DescriptionPanel").ForEach(description =>
            {
                if (description.style.display != DisplayStyle.None) description.style.display = DisplayStyle.None;
                if (!_descriptions.Add(description) || _costHolder == null) return;
                var row = description.parent;
                var external = row?.Q("ExternalSections");
                if (external == null) return;
                CarryStyles(external, _costHolder);
                _costs[external] = row;
                external.style.marginTop = RailGap;
                _costHolder.Add(external);
            });
            foreach (var cost in _costs)
            {
                var display = Shown(cost.Value) ? DisplayStyle.Flex : DisplayStyle.None;
                if (cost.Key.style.display != display) cost.Key.style.display = display;
            }
        }

        // In the tool panel and not hidden there.
        bool Shown(VisualElement e)
        {
            if (e.panel == null) return false;
            for (; e != null && e != _toolPanel; e = e.parent)
                if (e.resolvedStyle.display == DisplayStyle.None) return false;
            return e == _toolPanel;
        }

        // The style sheets the element got from its ancestors, up to the game's HUD root.
        void CarryStyles(VisualElement element, VisualElement to)
        {
            for (var e = element.parent; e != null && e != _gameUI; e = e.parent)
                for (int i = 0; i < e.styleSheets.count; i++)
                    if (!to.styleSheets.Contains(e.styleSheets[i])) to.styleSheets.Add(e.styleSheets[i]);
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
            var show = !IsOpen(drawer);
            CloseAll();
            Open(drawer, tab, show);
        }

        // The View drawer opens by visibility (see LayOutView), the Colony drawer by display.
        bool IsOpen(VisualElement drawer) => drawer == _viewDrawer ? drawer.visible : drawer.style.display != DisplayStyle.None;

        void CloseAll()
        {
            Open(_colonyDrawer, _colonyTab, false);
            Open(_viewDrawer, _viewTab, false);
        }

        void Open(VisualElement drawer, Button tab, bool show)
        {
            if (drawer == null) return;
            if (drawer == _viewDrawer) drawer.visible = show;
            else drawer.style.display = show ? DisplayStyle.Flex : DisplayStyle.None;
            tab?.EnableInClassList("button--active", show);
        }
    }
}
