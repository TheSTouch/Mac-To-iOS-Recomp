// Touch scrolling for desktop Qt apps on iOS. A finger on a QWidget app reaches
// widgets as the mouse events Qt makes of a touch, so a drag in a list or a text
// view selects instead of scrolling, and only the scroll bar scrolls. Here a
// one-finger drag inside any QAbstractScrollArea's viewport (item views, text
// views, QScrollArea, QScintilla) that has something to scroll moves the content
// with the finger, and a flick keeps it going and bounces at the ends, through a
// QScroller per viewport fed from an event filter on qApp:
//   - a press is held back until it is clear what it is. Released without moving
//     it is a tap: the press goes to the widget, then the release. Moved past the
//     drag distance it scrolls, and the widget never sees it;
//   - held still for kHoldMs it goes to the widget, and the drag that follows is
//     the widget's own (selecting text, dragging items); a double tap is passed as
//     the double click it is (selects a word);
//   - a drag the area cannot follow (sideways in a list that only scrolls down)
//     goes to the widget at once;
//   - sliders and splitter handles inside a scrolled area keep their drag, and
//     scroll bars are outside the viewport, so they still drag as before.
// Mouse events from a mouse or trackpad are left alone. Qt's own flick gesture
// (QScroller::grabGesture) is not used: on a touchscreen it scrolls and lets the
// widget select at the same time.
#include <QtCore/QBasicTimer>
#include <QtCore/QCoreApplication>
#include <QtCore/QEasingCurve>
#include <QtCore/QPointer>
#include <QtGui/QInputDevice>
#include <QtGui/QMouseEvent>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QAbstractScrollArea>
#include <QtWidgets/QAbstractSlider>
#include <QtWidgets/QApplication>
#include <QtWidgets/QScrollBar>
#include <QtWidgets/QScroller>
#include <QtWidgets/QScrollerProperties>
#include <QtWidgets/QSplitterHandle>
#include <QtWidgets/QWidget>

#include <memory>

// QCoreApplication::sendSpontaneousEvent is private. A held-back press has to
// arrive as the system's own would: QApplication gives focus on a click only then.
extern bool recompSendSpontaneousEvent(QObject *receiver, QEvent *event)
    __asm("__ZN16QCoreApplication20sendSpontaneousEventEP7QObjectP6QEvent");

namespace {

const int kHoldMs = 500;          // a press held this long is the widget's
const qreal kDragDistance = 12;   // points before a press becomes a scroll (RecompQtTouch.mm's drag distance)
const char *const kSetUp = "_recomp_touchScroll";
const char *const kUnit = "_recomp_scrollUnit";

bool fromTouch(const QMouseEvent *e)
{
    return e->source() == Qt::MouseEventSynthesizedByQt
        || (e->pointingDevice() && e->pointingDevice()->type() == QInputDevice::DeviceType::TouchScreen);
}

bool canScroll(QAbstractScrollArea *area)
{
    // Header views and other areas the app scrolls itself have no scroll bars.
    if (area->horizontalScrollBarPolicy() == Qt::ScrollBarAlwaysOff
        && area->verticalScrollBarPolicy() == Qt::ScrollBarAlwaysOff)
        return false;
    const QScrollBar *h = area->horizontalScrollBar(), *v = area->verticalScrollBar();
    return h->maximum() > h->minimum() || v->maximum() > v->minimum();
}

// The innermost scroll area with something to scroll whose viewport holds w,
// unless a widget on the way keeps its own drag.
QAbstractScrollArea *scrollAreaFor(QWidget *w)
{
    for (QWidget *p = w; p && !p->isWindow(); p = p->parentWidget()) {
        if (qobject_cast<QAbstractSlider *>(p) || qobject_cast<QSplitterHandle *>(p))
            return nullptr;
        auto *area = qobject_cast<QAbstractScrollArea *>(p->parentWidget());
        if (area && area->viewport() == p && canScroll(area))
            return area;
    }
    return nullptr;
}

QScroller *scrollerFor(QAbstractScrollArea *area)
{
    QWidget *viewport = area->viewport();
    QScroller *scroller = QScroller::scroller(viewport);
    if (viewport->property(kSetUp).toBool())
        return scroller;
    viewport->setProperty(kSetUp, true);
    // Item views scrolled per item would jump a row at a time under the finger.
    if (auto *view = qobject_cast<QAbstractItemView *>(area)) {
        view->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
        view->setHorizontalScrollMode(QAbstractItemView::ScrollPerPixel);
    }
    // Distances are in meters on the screen, speeds in meters per second.
    const qreal ppm = qMax<qreal>(1, scroller->pixelPerMeter().y());
    QScrollerProperties p = scroller->scrollerProperties();
    p.setScrollMetric(QScrollerProperties::DragStartDistance, kDragDistance / ppm);
    p.setScrollMetric(QScrollerProperties::AxisLockThreshold, 0.5);
    p.setScrollMetric(QScrollerProperties::MaximumVelocity, 1.5);
    p.setScrollMetric(QScrollerProperties::DecelerationFactor, 0.2);
    p.setScrollMetric(QScrollerProperties::ScrollingCurve, QEasingCurve(QEasingCurve::OutCubic));
    p.setScrollMetric(QScrollerProperties::OvershootDragResistanceFactor, 0.4);
    p.setScrollMetric(QScrollerProperties::OvershootDragDistanceFactor, 0.15);
    p.setScrollMetric(QScrollerProperties::OvershootScrollDistanceFactor, 0.08);
    p.setScrollMetric(QScrollerProperties::OvershootScrollTime, 0.4);
    p.setScrollMetric(QScrollerProperties::FrameRate, QVariant::fromValue(QScrollerProperties::Fps60));
    scroller->setScrollerProperties(p);
    return scroller;
}

class TouchScroll : public QObject
{
public:
    using QObject::QObject;

    bool eventFilter(QObject *object, QEvent *event) override
    {
        if (sending)
            return false;
        switch (event->type()) {
        case QEvent::MouseButtonPress:
        case QEvent::MouseButtonDblClick:
        case QEvent::MouseMove:
        case QEvent::MouseButtonRelease:
            if (object->isWidgetType() && fromTouch(static_cast<QMouseEvent *>(event)))
                return mouse(static_cast<QWidget *>(object), static_cast<QMouseEvent *>(event));
            return false;
        case QEvent::ScrollPrepare:
            if (object->property(kSetUp).toBool())
                return prepare(static_cast<QWidget *>(object), static_cast<QScrollPrepareEvent *>(event));
            return false;
        case QEvent::Scroll:
            if (object->property(kSetUp).toBool())
                return scroll(static_cast<QWidget *>(object), static_cast<QScrollEvent *>(event));
            return false;
        default:
            return false;
        }
    }

protected:
    void timerEvent(QTimerEvent *event) override
    {
        if (event->timerId() != hold.timerId())
            return QObject::timerEvent(event);
        hold.stop();
        if (mode != Pending)
            return;
        // Held still: the touch is the widget's from here on.
        if (scroller)
            scroller->stop();
        replay();
        mode = PassThrough;
    }

private:
    enum Mode { Idle, Pending, Scrolling, PassThrough };

    bool mouse(QWidget *w, QMouseEvent *e)
    {
        // A press or release the receiver ignored travels on to its parents.
        const bool propagated = e->timestamp() == lastTimestamp && e->type() == lastType;
        lastTimestamp = e->timestamp();
        lastType = e->type();
        if (propagated)
            return mode == Pending || mode == Scrolling;

        // When the finger was there (a UITouch's time), not when the event got here.
        const qint64 now = qint64(e->timestamp());
        switch (e->type()) {
        case QEvent::MouseButtonPress:
        case QEvent::MouseButtonDblClick: {
            // Qt sends the second press of a double click as the double click only.
            if (e->button() != Qt::LeftButton || e->buttons() != Qt::LeftButton)
                return mode == Pending || mode == Scrolling;
            reset();
            QAbstractScrollArea *area = scrollAreaFor(w);
            if (!area)
                return false;
            QScroller *s = scrollerFor(area);
            const QPointF at = area->viewport()->mapFromGlobal(e->globalPosition());
            if (s->state() == QScroller::Scrolling) {
                // A finger on moving content catches it (and is no tap), unless
                // it has nearly stopped.
                s->handleInput(QScroller::InputPress, at, now);
                if (s->state() == QScroller::Dragging) {
                    scroller = s;
                    viewport = area->viewport();
                    mode = Scrolling;
                    return true;
                }
            }
            s->handleInput(QScroller::InputPress, at, now);
            if (s->state() != QScroller::Pressed)
                return false;
            scroller = s;
            viewport = area->viewport();
            target = w;
            press.reset(static_cast<QMouseEvent *>(e->clone()));
            mode = Pending;
            hold.start(kHoldMs, this);
            return true;
        }
        case QEvent::MouseMove:
            if (mode != Pending && mode != Scrolling)
                return false;
            if (!scroller || !viewport) {
                reset();
                return false;
            }
            scroller->handleInput(QScroller::InputMove, viewport->mapFromGlobal(e->globalPosition()), now);
            if (scroller->state() == QScroller::Dragging) {
                hold.stop();
                press.reset();
                mode = Scrolling;
                return true;
            }
            if (mode == Pending && scroller->state() == QScroller::Inactive) {
                // A drag this area cannot follow: the widget's.
                hold.stop();
                replay();
                mode = PassThrough;
                return false;
            }
            return true;
        case QEvent::MouseButtonRelease: {
            const Mode was = mode;
            hold.stop();
            if (scroller && viewport && (was == Pending || was == Scrolling))
                scroller->handleInput(QScroller::InputRelease, viewport->mapFromGlobal(e->globalPosition()), now);
            if (was == Pending)
                replay();   // a tap: the press, then this release
            mode = Idle;
            press.reset();
            return was == Scrolling;
        }
        default:
            return false;
        }
    }

    void replay()
    {
        if (press && target) {
            sending = true;
            recompSendSpontaneousEvent(target, press.get());
            sending = false;
        }
        press.reset();
    }

    void reset()
    {
        hold.stop();
        press.reset();
        mode = Idle;
    }

    // QAbstractScrollArea gives QScroller its scroll bars' range, in their units:
    // lines in QPlainTextEdit and QScintilla, so a finger would move a line per
    // point. The range goes out in points here, a scroll bar step taken as its
    // page step's share of the viewport.
    bool prepare(QWidget *viewport, QScrollPrepareEvent *e)
    {
        auto *area = qobject_cast<QAbstractScrollArea *>(viewport->parentWidget());
        if (!area)
            return false;
        sending = true;
        QCoreApplication::sendEvent(viewport, e);
        sending = false;
        if (!e->isAccepted())
            return true;
        auto unit = [](const QScrollBar *bar, int extent) {
            const qreal u = bar->pageStep() > 0 ? qreal(extent) / bar->pageStep() : 1;
            return u < 2 ? qreal(1) : u;
        };
        const QPointF u(unit(area->horizontalScrollBar(), viewport->width()),
                        unit(area->verticalScrollBar(), viewport->height()));
        viewport->setProperty(kUnit, u);
        const QRectF range = e->contentPosRange();
        e->setContentPosRange(QRectF(range.x() * u.x(), range.y() * u.y(), range.width() * u.x(),
                                     range.height() * u.y()));
        e->setContentPos(QPointF(e->contentPos().x() * u.x(), e->contentPos().y() * u.y()));
        return true;
    }

    bool scroll(QWidget *viewport, QScrollEvent *e)
    {
        const QPointF u = viewport->property(kUnit).toPointF();
        if (u.isNull() || u == QPointF(1, 1))
            return false;
        QScrollEvent inUnits(QPointF(qRound(e->contentPos().x() / u.x()), qRound(e->contentPos().y() / u.y())),
                             e->overshootDistance(), e->scrollState());
        sending = true;
        QCoreApplication::sendEvent(viewport, &inUnits);
        sending = false;
        return true;
    }

    QBasicTimer hold;
    Mode mode = Idle;
    bool sending = false;
    QPointer<QScroller> scroller;
    QPointer<QWidget> viewport;
    QPointer<QWidget> target;
    std::unique_ptr<QMouseEvent> press;
    quint64 lastTimestamp = 0;
    QEvent::Type lastType = QEvent::None;
};

void startTouchScroll()
{
    if (!qobject_cast<QApplication *>(QCoreApplication::instance()))
        return;
    qApp->installEventFilter(new TouchScroll(qApp));
}

}

Q_COREAPP_STARTUP_FUNCTION(startTouchScroll)
