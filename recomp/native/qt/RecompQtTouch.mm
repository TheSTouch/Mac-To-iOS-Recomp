// Touch sizes for desktop Qt apps on iOS. A QWidget app keeps the Mac's mouse-sized
// controls (10 pt spin-box arrows, 12 pt dock buttons), which a finger misses. A
// proxy style over the app's own style raises the hit targets; drawing stays the
// app style's. Installed when the first widget is polished, once QApplication has
// set up its style and fonts, and again if the app replaces the style.
#include <QtCore/QCoreApplication>
#include <QtCore/QPointer>
#include <QtWidgets/QAbstractSpinBox>
#include <QtWidgets/QApplication>
#include <QtWidgets/QProxyStyle>
#include <QtWidgets/QStyleOption>
#include <QtWidgets/QWidget>

namespace {

const int kTarget = 44;          // menu items, tabs, buttons, combo boxes, line edits
const int kSpinButton = 32;      // spin-box up/down button width
const int kIndicator = 24;       // check box and radio button
const int kScrollBar = 18;
const int kScrollSlider = 44;    // shortest scroll-bar slider
const int kDockButton = 32;      // dock title-bar close and float buttons
const int kSeparator = 12;       // splitter and dock separator handles

class TouchStyle : public QProxyStyle
{
public:
    using QProxyStyle::QProxyStyle;

    int pixelMetric(PixelMetric metric, const QStyleOption *option, const QWidget *widget) const override
    {
        const int base = QProxyStyle::pixelMetric(metric, option, widget);
        switch (metric) {
        case PM_IndicatorWidth:
        case PM_IndicatorHeight:
        case PM_ExclusiveIndicatorWidth:
        case PM_ExclusiveIndicatorHeight:
            return qMax(base, kIndicator);
        case PM_ScrollBarExtent:
            return qMax(base, kScrollBar);
        case PM_ScrollBarSliderMin:
            return qMax(base, kScrollSlider);
        case PM_SplitterWidth:
        case PM_DockWidgetSeparatorExtent:
            return qMax(base, kSeparator);
        case PM_DockWidgetTitleBarButtonMargin: {
            // The button is its icon plus this margin on each side
            // (QDockWidgetTitleButton::sizeHint).
            int icon = QProxyStyle::pixelMetric(PM_SmallIconSize, nullptr, widget);
            if (QProxyStyle::styleHint(SH_DockWidget_ButtonsHaveFrame, nullptr, widget))
                icon = icon * 5 / 8;
            return qMax(base, (kDockButton - icon + 1) / 2);
        }
        default:
            return base;
        }
    }

    QSize sizeFromContents(ContentsType type, const QStyleOption *option, const QSize &contents,
                           const QWidget *widget) const override
    {
        QSize size = QProxyStyle::sizeFromContents(type, option, contents, widget);
        switch (type) {
        case CT_MenuItem:
            if (auto *item = qstyleoption_cast<const QStyleOptionMenuItem *>(option))
                if (item->menuItemType == QStyleOptionMenuItem::Separator)
                    break;
            size.setHeight(qMax(size.height(), kTarget));
            break;
        case CT_MenuBarItem:
        case CT_PushButton:
        case CT_ComboBox:
        case CT_LineEdit:
            size.setHeight(qMax(size.height(), kTarget));
            break;
        case CT_ToolButton:
            size = size.expandedTo(QSize(kTarget, kTarget));
            break;
        case CT_TabBarTab:
            if (auto *tab = qstyleoption_cast<const QStyleOptionTab *>(option)) {
                const bool vertical = tab->shape == QTabBar::RoundedWest || tab->shape == QTabBar::RoundedEast
                    || tab->shape == QTabBar::TriangularWest || tab->shape == QTabBar::TriangularEast;
                if (vertical)
                    size.setWidth(qMax(size.width(), kTarget));
                else
                    size.setHeight(qMax(size.height(), kTarget));
            }
            break;
        case CT_SpinBox:
            if (auto *spin = qstyleoption_cast<const QStyleOptionSpinBox *>(option)) {
                size.setHeight(qMax(size.height(), kTarget));
                if (spin->buttonSymbols != QAbstractSpinBox::NoButtons) {
                    QStyleOptionSpinBox sized(*spin);
                    sized.rect = QRect(QPoint(0, 0), size);
                    const int button = QProxyStyle::subControlRect(CC_SpinBox, &sized, SC_SpinBoxUp, widget).width();
                    size.rwidth() += qMax(0, kSpinButton - button);
                }
            }
            break;
        default:
            break;
        }
        return size;
    }

    // The spin box's up and down buttons grow towards the text; the text field
    // gives up the same width. Drawing and hit testing both ask the proxy.
    QRect subControlRect(ComplexControl control, const QStyleOptionComplex *option, SubControl sub,
                         const QWidget *widget) const override
    {
        QRect rect = QProxyStyle::subControlRect(control, option, sub, widget);
        if (control != CC_SpinBox || !(sub == SC_SpinBoxUp || sub == SC_SpinBoxDown || sub == SC_SpinBoxEditField))
            return rect;
        auto *spin = qstyleoption_cast<const QStyleOptionSpinBox *>(option);
        if (!spin || spin->buttonSymbols == QAbstractSpinBox::NoButtons)
            return rect;
        const int button = QProxyStyle::subControlRect(control, option, SC_SpinBoxUp, widget).width();
        const int grow = qMax(0, kSpinButton - button);
        if (!grow)
            return rect;
        // In left-to-right coordinates, where the buttons are at the right.
        QRect logical = visualRect(option->direction, option->rect, rect);
        if (sub == SC_SpinBoxEditField)
            logical.setRight(logical.right() - grow);
        else
            logical.setLeft(logical.left() - grow);
        return visualRect(option->direction, option->rect, logical);
    }
};

QPointer<QStyle> touchStyle;

void installTouchStyle()
{
    QStyle *base = QApplication::style();
    // With an app-wide style sheet, the app style is a style sheet style in front
    // of the real one, which QApplication::setStyleSheet made its child. The proxy
    // goes over the real one, and setStyle puts a new style sheet style in front.
    if (base->inherits("QStyleSheetStyle"))
        base = base->findChild<QStyle *>(QString(), Qt::FindDirectChildrenOnly);
    if (!base) {
        fprintf(stderr, "[recomp] touch style: no style behind the app's style sheet, not installed\n");
        return;
    }
    touchStyle = new TouchStyle(base);
    QApplication::setStyle(touchStyle);
}

class TouchSetup : public QObject
{
public:
    using QObject::QObject;

    bool eventFilter(QObject *object, QEvent *event) override
    {
        // Seen before the widget's own polish, so it is polished with the new style.
        // The proxy goes away when the app sets another style: wrap that one too.
        if (event->type() == QEvent::Polish && object->isWidgetType() && !touchStyle && !gaveUp) {
            installTouchStyle();
            gaveUp = !touchStyle;
        }
        // A style sheet anywhere in the app puts a style sheet style in front, which
        // sizes a spin box from its text alone, never asking the style behind it
        // (QStyleSheetStyle::sizeFromContents). Its height is raised here instead,
        // unless the spin box has a style sheet of its own.
        if (event->type() == QEvent::Polish) {
            if (auto *spin = qobject_cast<QAbstractSpinBox *>(object))
                if (spin->style()->inherits("QStyleSheetStyle") && spin->styleSheet().isEmpty()
                    && spin->minimumHeight() < kTarget && spin->maximumHeight() >= kTarget)
                    spin->setMinimumHeight(kTarget);
        }
        return false;
    }

private:
    bool gaveUp = false;
};

void startTouch()
{
    if (qobject_cast<QApplication *>(QCoreApplication::instance()))
        qApp->installEventFilter(new TouchSetup(qApp));
}

}

Q_COREAPP_STARTUP_FUNCTION(startTouch)
