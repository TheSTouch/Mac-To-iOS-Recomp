// Dock drawers for desktop Qt apps on iOS. On an 11-inch iPad a main window's docks
// leave little of its central widget, and a dock only closes through the small button
// in its title bar. So the right and the bottom dock areas become drawers: a handle on
// that edge of the central widget hides every dock in the area with one tap, and the
// next tap brings back the ones that were open. A dock the app opens itself (from its
// View menu) opens the drawer. Open or closed is kept per area in QSettings
// (recomp/drawers/right, recomp/drawers/bottom; the docks a closed drawer hid under
// recomp/drawerDocks/<area>) and applied once the app has restored its own layout.
// First launch: both closed.
//
// Two more controls on the central widget: a grip on its left edge, while docks are open
// on the left, resizes them by dragging (a tap switches between an even split and the
// width set last), and a button in its top-right corner shows the central widget alone:
// every dock and the window's toolbars hide, and the next tap brings back what was open.
//
// Test hook: an empty `recomp-drawers` file in Documents logs each drawer's state, its
// handle's screen rectangle (for recomp-click) and the docks in its area.
#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QPointer>
#include <QtCore/QSettings>
#include <QtCore/QTimer>
#include <QtGui/QMouseEvent>
#include <QtGui/QPainter>
#include <QtGui/QPainterPath>
#include <QtWidgets/QApplication>
#include <QtWidgets/QDockWidget>
#include <QtWidgets/QMainWindow>
#include <QtWidgets/QToolBar>

#include <algorithm>
#include <cstdlib>
#include <functional>

namespace {

// Points (Qt's iOS units): a touch target at least 44 long, 28 across.
const int HandleLength = 64;
const int HandleDepth = 28;

class Handle : public QWidget
{
public:
    enum Kind { Right, Bottom, Grip, Full };

    Handle(Kind kind, QWidget *parent) : QWidget(parent), kind(kind)
    {
        setFixedSize(kind == Bottom ? QSize(HandleLength, HandleDepth)
                     : kind == Full ? QSize(44, 44)
                                    : QSize(HandleDepth, HandleLength));
    }

    const Kind kind;
    bool open = false; // a drawer's docks shown; for Full, the central widget alone
    std::function<void()> tapped;
    std::function<void(int, bool)> dragged; // Grip: points moved right since the press, first move

protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing);
        QColor fill = palette().color(QPalette::Button);
        fill.setAlpha(pressed ? 235 : 180);
        p.setPen(QPen(palette().color(QPalette::Mid), 1));
        p.setBrush(fill);
        p.drawRoundedRect(QRectF(rect()).adjusted(0.5, 0.5, -0.5, -0.5), 6, 6);

        const QPointF c = QRectF(rect()).center();
        const qreal s = 5;
        QPainterPath chevron;
        if (kind == Grip) {
            chevron.moveTo(c.x() - 3, c.y() - 12);
            chevron.lineTo(c.x() - 3, c.y() + 12);
            chevron.moveTo(c.x() + 3, c.y() - 12);
            chevron.lineTo(c.x() + 3, c.y() + 12);
        } else if (kind == Full) {
            // Four corners, pointing out to fill the screen, in to go back.
            const qreal o = 11, i = 4;
            for (const QPointF &q : {QPointF(-1, -1), QPointF(1, -1), QPointF(1, 1), QPointF(-1, 1)}) {
                const QPointF tip = c + (open ? q * i : q * o);
                const qreal toward = open ? 1 : -1; // the arms run back toward the centre when out
                chevron.moveTo(tip + QPointF(toward * q.x() * 6, 0));
                chevron.lineTo(tip);
                chevron.lineTo(tip + QPointF(0, toward * q.y() * 6));
            }
        } else if (kind == Right) {
            // The chevron points the way the drawer will move: out of the screen when open.
            const qreal d = open ? s / 2 : -s / 2;
            chevron.moveTo(c.x() - d, c.y() - s * 1.6);
            chevron.lineTo(c.x() + d, c.y());
            chevron.lineTo(c.x() - d, c.y() + s * 1.6);
        } else {
            const qreal d = open ? s / 2 : -s / 2;
            chevron.moveTo(c.x() - s * 1.6, c.y() - d);
            chevron.lineTo(c.x(), c.y() + d);
            chevron.lineTo(c.x() + s * 1.6, c.y() - d);
        }
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(palette().color(QPalette::ButtonText), 2.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawPath(chevron);
    }

    void mousePressEvent(QMouseEvent *event) override
    {
        pressed = true;
        dragging = false;
        pressX = event->globalPosition().x();
        update();
        event->accept();
    }

    void mouseMoveEvent(QMouseEvent *event) override
    {
        event->accept();
        const int dx = qRound(event->globalPosition().x() - pressX);
        if (!pressed || !dragged || (!dragging && std::abs(dx) < 8))
            return;
        dragged(dx, !dragging);
        dragging = true;
    }

    void mouseReleaseEvent(QMouseEvent *event) override
    {
        pressed = false;
        update();
        event->accept();
        if (!dragging && rect().contains(event->position().toPoint()) && tapped)
            tapped();
        dragging = false;
    }

private:
    bool pressed = false, dragging = false;
    qreal pressX = 0;
};

class Drawers : public QObject
{
public:
    explicit Drawers(QMainWindow *window) : QObject(window), window(window)
    {
        for (Drawer &d : drawers) {
            d.handle = new Handle(d.area == Qt::RightDockWidgetArea ? Handle::Right : Handle::Bottom, window);
            d.handle->tapped = [this, &d] { toggle(d); };
            d.handle->hide();
        }
        grip = new Handle(Handle::Grip, window);
        grip->dragged = [this](int dx, bool first) { resizeLeft(dx, first); };
        grip->tapped = [this] { splitLeft(); };
        grip->hide();
        full = new Handle(Handle::Full, window);
        full->tapped = [this] { toggleFull(); };
        full->hide();
        window->installEventFilter(this);
        // The app restores its dock layout before or as it first shows the window.
        QTimer::singleShot(0, this, [this] { restore(); });
    }

    void log() const
    {
        for (const Drawer &d : drawers) {
            const QRect r(d.handle->mapToGlobal(QPoint(0, 0)), d.handle->size());
            fprintf(stderr, "[recomp] drawer %s %s, handle %s at %d,%d %dx%d\n", d.name,
                    d.handle->open ? "open" : "closed", d.handle->isVisible() ? "shown" : "hidden", r.x(), r.y(),
                    r.width(), r.height());
            for (QDockWidget *dock : docks(d))
                fprintf(stderr, "[recomp]   %s \"%s\" %s\n", qPrintable(dock->objectName()),
                        qPrintable(dock->windowTitle()), dock->isHidden() ? "hidden" : "shown");
        }
        for (const Handle *h : {grip, full}) {
            const QRect r(h->mapToGlobal(QPoint(0, 0)), h->size());
            fprintf(stderr, "[recomp] %s%s, %s at %d,%d %dx%d\n", h == grip ? "left grip" : "central-alone button",
                    h == full ? (full->open ? " (on)" : " (off)") : "", h->isVisible() ? "shown" : "hidden", r.x(),
                    r.y(), r.width(), r.height());
        }
        if (QDockWidget *left = shownLeft().value(0))
            fprintf(stderr, "[recomp] left docks %d wide\n", left->width());
    }

protected:
    bool eventFilter(QObject *object, QEvent *event) override
    {
        switch (event->type()) {
        case QEvent::Show:
        case QEvent::Hide:
        case QEvent::Resize:
        case QEvent::Move:
        case QEvent::LayoutRequest:
        case QEvent::ChildAdded:
        case QEvent::ChildRemoved:
            if (object == window || object->isWidgetType())
                schedule();
            break;
        default:
            break;
        }
        return false;
    }

private:
    struct Drawer
    {
        Qt::DockWidgetArea area;
        const char *name;
        Handle *handle = nullptr;
        QList<QPointer<QDockWidget>> hid; // what closing it hid, to bring back
    };

    QMainWindow *const window;
    Drawer drawers[2] = {{Qt::RightDockWidgetArea, "right"}, {Qt::BottomDockWidgetArea, "bottom"}};
    Handle *grip = nullptr, *full = nullptr;
    QList<QPointer<QWidget>> fullHid; // what showing the central widget alone hid
    int leftStart = 0, leftSet = 0;   // left docks' width when a drag began, and after the last one
    QList<QPointer<QObject>> watched;
    bool restored = false, scheduled = false;

    QList<QDockWidget *> shownLeft() const
    {
        QList<QDockWidget *> out;
        for (QDockWidget *dock : window->findChildren<QDockWidget *>(Qt::FindDirectChildrenOnly))
            if (!dock->isFloating() && !dock->isHidden() && window->dockWidgetArea(dock) == Qt::LeftDockWidgetArea)
                out.append(dock);
        return out;
    }

    void setLeft(const QList<QDockWidget *> &left, int width)
    {
        width = std::clamp(width, 120, std::max(120, window->width() - 160));
        window->resizeDocks(left, QList<int>(left.size(), width), Qt::Horizontal);
    }

    void resizeLeft(int dx, bool first)
    {
        const QList<QDockWidget *> left = shownLeft();
        if (left.isEmpty())
            return;
        if (first)
            leftStart = left.first()->width();
        setLeft(left, leftStart + dx);
        leftSet = left.first()->width();
    }

    // A tap: an even split, or back to the width before it.
    void splitLeft()
    {
        const QList<QDockWidget *> left = shownLeft();
        if (left.isEmpty())
            return;
        // Even: the left docks as wide as the central widget, sharing the space they have.
        const int now = left.first()->width();
        const int even = window->centralWidget() ? (now + window->centralWidget()->width()) / 2 : window->width() / 2;
        if (std::abs(now - even) > 24) {
            leftSet = now;
            setLeft(left, even);
        } else {
            setLeft(left, leftSet > 0 && std::abs(leftSet - even) > 24 ? leftSet : even * 2 / 3);
        }
    }

    void toggleFull()
    {
        if (!full->open) {
            fullHid.clear();
            for (QDockWidget *dock : window->findChildren<QDockWidget *>(Qt::FindDirectChildrenOnly))
                if (!dock->isFloating() && !dock->isHidden())
                    fullHid.append(dock);
            for (QToolBar *bar : window->findChildren<QToolBar *>(Qt::FindDirectChildrenOnly))
                if (!bar->isHidden())
                    fullHid.append(bar);
            full->open = true;
            for (QWidget *w : fullHid)
                w->setVisible(false);
        } else {
            full->open = false;
            for (const QPointer<QWidget> &w : fullHid)
                if (w)
                    w->setVisible(true);
            fullHid.clear();
        }
        full->update();
        update();
        fprintf(stderr, "[recomp] central widget %s\n", full->open ? "alone" : "with its docks");
    }

    QList<QDockWidget *> docks(const Drawer &d) const
    {
        QList<QDockWidget *> out;
        for (QDockWidget *dock : window->findChildren<QDockWidget *>(Qt::FindDirectChildrenOnly))
            if (!dock->isFloating() && window->dockWidgetArea(dock) == d.area)
                out.append(dock);
        return out;
    }

    bool isOpen(const Drawer &d) const
    {
        for (QDockWidget *dock : docks(d))
            if (!dock->isHidden())
                return true;
        return false;
    }

    void close(Drawer &d)
    {
        d.hid.clear();
        for (QDockWidget *dock : docks(d))
            if (!dock->isHidden())
                d.hid.append(dock);
        for (QDockWidget *dock : d.hid)
            dock->setVisible(false);
    }

    void open(Drawer &d)
    {
        QList<QDockWidget *> show;
        const QList<QDockWidget *> area = docks(d);
        for (const QPointer<QDockWidget> &dock : d.hid)
            if (dock && area.contains(dock))
                show.append(dock);
        if (show.isEmpty())
            show = area;
        for (QDockWidget *dock : show)
            dock->setVisible(true);
        d.hid.clear();
    }

    void toggle(Drawer &d)
    {
        if (isOpen(d))
            close(d);
        else
            open(d);
        update();
        fprintf(stderr, "[recomp] drawer %s %s\n", d.name, d.handle->open ? "opened" : "closed");
    }

    void restore()
    {
        QSettings settings;
        for (Drawer &d : drawers) {
            const bool open = settings.value(QStringLiteral("recomp/drawers/") + d.name, false).toBool();
            const QStringList names = settings.value(QStringLiteral("recomp/drawerDocks/") + d.name).toStringList();
            const QList<QDockWidget *> area = docks(d);
            d.hid.clear();
            for (QDockWidget *dock : area)
                if (names.contains(dock->objectName()))
                    d.hid.append(dock);
            if (open && !isOpen(d))
                this->open(d);
            else if (!open && isOpen(d))
                close(d);
        }
        restored = true;
        update();
        // Saved now, not only on a change: on first launch the docks the app's own layout
        // opened are what the drawer closed, and what its first tap brings back. Unsaved,
        // the app starts them hidden next time and that tap opens every dock in the area.
        for (const Drawer &d : drawers)
            save(d);
        log();
    }

    void save(const Drawer &d) const
    {
        QSettings settings;
        settings.setValue(QStringLiteral("recomp/drawers/") + d.name, d.handle->open);
        QStringList names;
        for (const QPointer<QDockWidget> &dock : d.hid)
            if (dock)
                names.append(dock->objectName());
        settings.setValue(QStringLiteral("recomp/drawerDocks/") + d.name, names);
    }

    void schedule()
    {
        if (scheduled)
            return;
        scheduled = true;
        QMetaObject::invokeMethod(this, [this] {
            scheduled = false;
            update();
        }, Qt::QueuedConnection);
    }

    // Follows the docks' visibility and keeps the handles on the central widget's edges.
    void update()
    {
        watch(window->centralWidget());
        for (QDockWidget *dock : window->findChildren<QDockWidget *>(Qt::FindDirectChildrenOnly))
            watch(dock);
        QWidget *central = window->centralWidget();
        if (full->open) {
            // A dock the app opens (an error log, say) ends the central widget alone.
            for (QDockWidget *dock : window->findChildren<QDockWidget *>(Qt::FindDirectChildrenOnly))
                if (!dock->isFloating() && !dock->isHidden()) {
                    toggleFull();
                    return;
                }
        }
        const bool onCentral = central && central->isVisible();
        const QRect c = onCentral ? edges(central) : QRect();
        for (Drawer &d : drawers) {
            const bool open = isOpen(d);
            if (open != d.handle->open && !full->open) {
                d.handle->open = open;
                d.handle->update();
                if (restored)
                    save(d);
            }
            const bool shown = onCentral && !full->open && !docks(d).isEmpty();
            if (shown) {
                if (d.area == Qt::RightDockWidgetArea)
                    d.handle->move(c.right() + 1 - d.handle->width(), c.center().y() - d.handle->height() / 2);
                else
                    d.handle->move(c.center().x() - d.handle->width() / 2, c.bottom() + 1 - d.handle->height());
                d.handle->raise();
            }
            d.handle->setVisible(shown);
        }
        const bool gripShown = onCentral && !full->open && !shownLeft().isEmpty();
        if (gripShown) {
            grip->move(c.left(), c.center().y() - grip->height() / 2);
            grip->raise();
        }
        grip->setVisible(gripShown);
        if (onCentral) {
            full->move(c.right() + 1 - 6 - full->width(), c.top() + 6);
            full->raise();
        }
        full->setVisible(onCentral);
    }

    // The central widget's rectangle in the window, less the toolbars it has along its
    // right and bottom edges (a 3D view's own controls), so the handles don't cover them.
    QRect edges(QWidget *central)
    {
        QRect c = central->geometry();
        const QRect inner = central->rect();
        int right = inner.right(), bottom = inner.bottom();
        for (QToolBar *bar : central->findChildren<QToolBar *>()) {
            if (!bar->isVisible())
                continue;
            watch(bar);
            const QRect r(bar->mapTo(central, QPoint(0, 0)), bar->size());
            if (r.bottom() >= inner.bottom() - 2 && r.width() > r.height())
                bottom = std::min(bottom, r.top() - 1);
            else if (r.right() >= inner.right() - 2 && r.height() > r.width())
                right = std::min(right, r.left() - 1);
        }
        c.setRight(c.left() + right);
        c.setBottom(c.top() + bottom);
        return c;
    }

    void watch(QObject *object)
    {
        if (!object || watched.contains(object))
            return;
        watched.removeAll(nullptr);
        watched.append(object);
        object->installEventFilter(this);
    }
};

class DrawerInstaller : public QObject
{
public:
    using QObject::QObject;

    bool eventFilter(QObject *object, QEvent *event) override
    {
        if (event->type() == QEvent::Show) {
            auto *window = qobject_cast<QMainWindow *>(object);
            if (window && window->isWindow() && !window->property("recompDrawers").isValid()) {
                window->setProperty("recompDrawers", true);
                all.append(new Drawers(window));
            }
        }
        return false;
    }

    QList<QPointer<Drawers>> all;
};

void startDrawers()
{
    if (!qobject_cast<QApplication *>(QCoreApplication::instance()))
        return;
    auto *installer = new DrawerInstaller(qApp);
    qApp->installEventFilter(installer);
    QMetaObject::invokeMethod(qApp, [installer] {
        QTimer *timer = new QTimer(installer);
        QObject::connect(timer, &QTimer::timeout, installer, [installer] {
            QFile request(QDir::homePath() + QStringLiteral("/Documents/recomp-drawers"));
            if (!request.exists())
                return;
            request.remove();
            for (const QPointer<Drawers> &d : installer->all)
                if (d)
                    d->log();
        });
        timer->start(1000);
    }, Qt::QueuedConnection);
}

}

Q_COREAPP_STARTUP_FUNCTION(startDrawers)
