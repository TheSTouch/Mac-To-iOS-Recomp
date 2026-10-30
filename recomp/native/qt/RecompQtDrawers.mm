// Dock drawers for desktop Qt apps on iOS. On an 11-inch iPad a main window's docks
// leave little of its central widget, and a dock only closes through the small button
// in its title bar. So the left, right and bottom dock areas become drawers, each with a
// handle on that edge of the central widget:
//   - while the area's docks are open, the handle is a grip: dragging it resizes them,
//     and dragging past their minimum size closes them all (a tap switches between an
//     even split with the central widget and the size set last);
//   - while they are closed, a tap brings back the ones that were open, at the size they
//     had, and dragging out opens them at the size dragged to.
// A dock the app opens itself (from its View menu) opens the drawer. Open or closed is
// kept per area in QSettings (recomp/drawers/<area>; the docks a closed drawer hid under
// recomp/drawerDocks/<area>) and applied once the app has restored its own layout. First
// launch: right and bottom closed, left as the app lays it out.
//
// A button in the central widget's top-right corner shows it alone: every open drawer
// closes and the window's toolbars hide, and the next tap brings back what was open. The
// handles stay, so a drawer can be opened meanwhile, which ends it.
//
// Test hook: an empty `recomp-drawers` file in Documents logs each drawer's state and
// size, its handle's screen rectangle (for recomp-click and recomp-swipe) and the docks in
// its area.
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
// How far past the docks' minimum size a drag has to go to close them.
const int CloseSlack = 48;

class Handle : public QWidget
{
public:
    enum Kind { Left, Right, Bottom, Full };

    Handle(Kind kind, QWidget *parent) : QWidget(parent), kind(kind)
    {
        setFixedSize(kind == Bottom ? QSize(HandleLength, HandleDepth)
                     : kind == Full ? QSize(44, 44)
                                    : QSize(HandleDepth, HandleLength));
    }

    const Kind kind;
    bool open = false; // a drawer's docks shown; for Full, the central widget alone
    std::function<void()> tapped;
    std::function<void(int, bool)> dragged; // points the docks grow by since the press, first move

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
        QPainterPath mark;
        if (kind == Full) {
            // Four corners, pointing out to fill the screen, in to go back.
            const qreal o = 11, i = 4;
            for (const QPointF &q : {QPointF(-1, -1), QPointF(1, -1), QPointF(1, 1), QPointF(-1, 1)}) {
                const QPointF tip = c + (open ? q * i : q * o);
                const qreal toward = open ? 1 : -1; // the arms run back toward the centre when out
                mark.moveTo(tip + QPointF(toward * q.x() * 6, 0));
                mark.lineTo(tip);
                mark.lineTo(tip + QPointF(0, toward * q.y() * 6));
            }
        } else if (open) {
            // A grip: two bars along the edge.
            if (kind == Bottom) {
                mark.moveTo(c.x() - 12, c.y() - 3);
                mark.lineTo(c.x() + 12, c.y() - 3);
                mark.moveTo(c.x() - 12, c.y() + 3);
                mark.lineTo(c.x() + 12, c.y() + 3);
            } else {
                mark.moveTo(c.x() - 3, c.y() - 12);
                mark.lineTo(c.x() - 3, c.y() + 12);
                mark.moveTo(c.x() + 3, c.y() - 12);
                mark.lineTo(c.x() + 3, c.y() + 12);
            }
        } else if (kind == Bottom) {
            // A chevron pointing the way the drawer comes out.
            mark.moveTo(c.x() - s * 1.6, c.y() + s / 2);
            mark.lineTo(c.x(), c.y() - s / 2);
            mark.lineTo(c.x() + s * 1.6, c.y() + s / 2);
        } else {
            const qreal d = kind == Left ? s / 2 : -s / 2;
            mark.moveTo(c.x() - d, c.y() - s * 1.6);
            mark.lineTo(c.x() + d, c.y());
            mark.lineTo(c.x() - d, c.y() + s * 1.6);
        }
        p.setBrush(Qt::NoBrush);
        p.setPen(QPen(palette().color(QPalette::ButtonText), 2.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p.drawPath(mark);
    }

    void mousePressEvent(QMouseEvent *event) override
    {
        pressed = true;
        dragging = false;
        pressAt = event->globalPosition();
        update();
        event->accept();
    }

    void mouseMoveEvent(QMouseEvent *event) override
    {
        event->accept();
        const QPointF moved = event->globalPosition() - pressAt;
        const int along = qRound(kind == Bottom ? moved.y() : moved.x());
        if (!pressed || !dragged || (!dragging && std::abs(along) < 8))
            return;
        // The docks grow away from the central widget: right of a left edge, left of a
        // right edge, up from a bottom edge.
        dragged(kind == Left ? along : -along, !dragging);
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
    QPointF pressAt;
};

class Drawers : public QObject
{
public:
    explicit Drawers(QMainWindow *window) : QObject(window), window(window)
    {
        for (Drawer &d : drawers) {
            d.handle = new Handle(d.kind, window);
            d.handle->tapped = [this, &d] { tap(d); };
            d.handle->dragged = [this, &d](int grow, bool first) { drag(d, grow, first); };
            d.handle->hide();
        }
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
            fprintf(stderr, "[recomp] drawer %s %s", d.name, d.handle->open ? "open" : "closed");
            if (d.handle->open)
                fprintf(stderr, " %d pt (minimum %d)", size(d), minimum(d));
            fprintf(stderr, ", handle %s at %d,%d %dx%d\n", d.handle->isVisible() ? "shown" : "hidden", r.x(), r.y(),
                    r.width(), r.height());
            for (QDockWidget *dock : docks(d))
                fprintf(stderr, "[recomp]   %s \"%s\" %s\n", qPrintable(dock->objectName()),
                        qPrintable(dock->windowTitle()), dock->isHidden() ? "hidden" : "shown");
        }
        const QRect r(full->mapToGlobal(QPoint(0, 0)), full->size());
        fprintf(stderr, "[recomp] central-alone button (%s), %s at %d,%d %dx%d\n", full->open ? "on" : "off",
                full->isVisible() ? "shown" : "hidden", r.x(), r.y(), r.width(), r.height());
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
        Handle::Kind kind;
        Handle *handle = nullptr;
        QList<QPointer<QDockWidget>> hid; // what closing it hid, to bring back
        int was = 0;                      // its size before it closed, to open it at
        int start = 0;                    // its size when a drag began, 0 when closed
        int set = 0;                      // its size after the last drag
        bool byFull = false;              // closed by the central-alone button
    };

    QMainWindow *const window;
    Drawer drawers[3] = {{Qt::LeftDockWidgetArea, "left", Handle::Left},
                         {Qt::RightDockWidgetArea, "right", Handle::Right},
                         {Qt::BottomDockWidgetArea, "bottom", Handle::Bottom}};
    Handle *full = nullptr;
    QList<QPointer<QToolBar>> fullHid; // the toolbars showing the central widget alone hid
    QList<QPointer<QObject>> watched;
    bool restored = false, scheduled = false;

    static Qt::Orientation across(const Drawer &d)
    {
        return d.area == Qt::BottomDockWidgetArea ? Qt::Vertical : Qt::Horizontal;
    }

    QList<QDockWidget *> docks(const Drawer &d) const
    {
        QList<QDockWidget *> out;
        for (QDockWidget *dock : window->findChildren<QDockWidget *>(Qt::FindDirectChildrenOnly))
            if (!dock->isFloating() && window->dockWidgetArea(dock) == d.area)
                out.append(dock);
        return out;
    }

    // The docks shown in the area. Tabbed docks all count as visible, and the ones behind
    // the current tab keep the size they had when they were last on top.
    QList<QDockWidget *> visible(const Drawer &d) const
    {
        QList<QDockWidget *> out;
        for (QDockWidget *dock : docks(d))
            if (dock->isVisible())
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

    int extent(const Drawer &d, const QWidget *w) const
    {
        return across(d) == Qt::Vertical ? w->height() : w->width();
    }

    // The area's depth: its biggest dock, the current tab of tabbed ones.
    int size(const Drawer &d) const
    {
        int most = 0;
        for (QDockWidget *dock : visible(d))
            most = std::max(most, extent(d, dock));
        return most;
    }

    int maximum(const Drawer &d) const
    {
        return std::max(120, extent(d, window) - 160);
    }

    // The smallest the docks it shows (or would show) allow, at least 60 pt.
    int minimum(const Drawer &d) const
    {
        QList<QDockWidget *> list = visible(d);
        if (list.isEmpty())
            list = toOpen(d);
        int least = 60;
        for (QDockWidget *dock : list) {
            const QSize m = dock->minimumSizeHint().expandedTo(dock->minimumSize());
            least = std::max(least, across(d) == Qt::Vertical ? m.height() : m.width());
        }
        return std::min(least, maximum(d) / 2);
    }

    void resize(const Drawer &d, int to)
    {
        const QList<QDockWidget *> shown = visible(d);
        if (!shown.isEmpty())
            window->resizeDocks(shown, QList<int>(shown.size(), std::clamp(to, minimum(d), maximum(d))), across(d));
    }

    void close(Drawer &d)
    {
        d.was = size(d);
        d.hid.clear();
        for (QDockWidget *dock : docks(d))
            if (!dock->isHidden())
                d.hid.append(dock);
        for (QDockWidget *dock : d.hid)
            dock->setVisible(false);
    }

    QList<QDockWidget *> toOpen(const Drawer &d) const
    {
        QList<QDockWidget *> show;
        const QList<QDockWidget *> area = docks(d);
        for (const QPointer<QDockWidget> &dock : d.hid)
            if (dock && area.contains(dock))
                show.append(dock);
        return show.isEmpty() ? area : show;
    }

    void open(Drawer &d, int at)
    {
        for (QDockWidget *dock : toOpen(d))
            dock->setVisible(true);
        d.hid.clear();
        if (at > 0) {
            resize(d, at);
            // Docks just shown are laid out with the window, after this.
            QTimer::singleShot(0, this, [this, &d, at] {
                if (isOpen(d))
                    resize(d, at);
            });
        }
    }

    void tap(Drawer &d)
    {
        if (isOpen(d))
            split(d);
        else
            open(d, d.was);
        update();
        fprintf(stderr, "[recomp] drawer %s %s\n", d.name, isOpen(d) ? "open" : "closed");
    }

    // A tap on a grip: as big as the central widget, or back to the size before.
    void split(Drawer &d)
    {
        QWidget *central = window->centralWidget();
        const int now = size(d);
        const int even = central ? (now + extent(d, central)) / 2 : extent(d, window) / 2;
        if (std::abs(now - even) > 24) {
            d.set = now;
            resize(d, even);
        } else {
            resize(d, d.set > 0 && std::abs(d.set - even) > 24 ? d.set : even * 2 / 3);
        }
    }

    // Past the docks' minimum by CloseSlack they close; back within it, in the same
    // drag or from a closed drawer, they open at the size dragged to.
    void drag(Drawer &d, int grow, bool first)
    {
        if (first)
            d.start = isOpen(d) ? size(d) : 0;
        const int to = d.start + grow;
        if (to < minimum(d) - CloseSlack) {
            if (isOpen(d)) {
                close(d);
                d.was = d.start;
                fprintf(stderr, "[recomp] drawer %s closed by dragging\n", d.name);
            }
        } else if (!isOpen(d)) {
            open(d, to);
            fprintf(stderr, "[recomp] drawer %s opened by dragging\n", d.name);
        } else {
            resize(d, to);
            d.set = size(d);
        }
        update();
    }

    void toggleFull()
    {
        if (!full->open) {
            for (Drawer &d : drawers) {
                d.byFull = isOpen(d);
                if (d.byFull)
                    close(d);
            }
            fullHid.clear();
            for (QToolBar *bar : window->findChildren<QToolBar *>(Qt::FindDirectChildrenOnly))
                if (!bar->isHidden())
                    fullHid.append(bar);
            for (QToolBar *bar : fullHid)
                bar->setVisible(false);
            full->open = true;
        } else {
            full->open = false;
            for (Drawer &d : drawers)
                if (d.byFull && !isOpen(d))
                    open(d, d.was);
            endFull();
        }
        full->update();
        update();
        fprintf(stderr, "[recomp] central widget %s\n", full->open ? "alone" : "with its docks");
    }

    void endFull()
    {
        full->open = false;
        full->update();
        for (Drawer &d : drawers)
            d.byFull = false;
        for (const QPointer<QToolBar> &bar : fullHid)
            if (bar)
                bar->setVisible(true);
        fullHid.clear();
        // What is open and closed from here on is the user's layout.
        if (restored)
            for (const Drawer &d : drawers)
                save(d);
    }

    void restore()
    {
        QSettings settings;
        for (Drawer &d : drawers) {
            const QVariant saved = settings.value(QStringLiteral("recomp/drawers/") + d.name);
            // Never saved: right and bottom closed, left as the app has it.
            const bool open = saved.isValid() ? saved.toBool()
                              : d.area == Qt::LeftDockWidgetArea ? isOpen(d) : false;
            const QStringList names = settings.value(QStringLiteral("recomp/drawerDocks/") + d.name).toStringList();
            const QList<QDockWidget *> area = docks(d);
            d.hid.clear();
            for (QDockWidget *dock : area)
                if (names.contains(dock->objectName()))
                    d.hid.append(dock);
            if (open && !isOpen(d))
                this->open(d, 0);
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
        settings.setValue(QStringLiteral("recomp/drawers/") + d.name, isOpen(d));
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
        // A drawer opened meanwhile (by its handle or the app) ends the central widget alone.
        if (full->open)
            for (const Drawer &d : drawers)
                if (isOpen(d)) {
                    endFull();
                    break;
                }
        QWidget *central = window->centralWidget();
        const bool onCentral = central && central->isVisible();
        const QRect c = onCentral ? edges(central) : QRect();
        for (Drawer &d : drawers) {
            const bool open = isOpen(d);
            if (open != d.handle->open) {
                d.handle->open = open;
                d.handle->update();
                // Closed by the central-alone button: the layout before it is what is kept.
                if (restored && !full->open)
                    save(d);
            }
            const bool shown = onCentral && !docks(d).isEmpty();
            if (shown) {
                if (d.area == Qt::LeftDockWidgetArea)
                    d.handle->move(c.left(), c.center().y() - d.handle->height() / 2);
                else if (d.area == Qt::RightDockWidgetArea)
                    d.handle->move(c.right() + 1 - d.handle->width(), c.center().y() - d.handle->height() / 2);
                else
                    d.handle->move(c.center().x() - d.handle->width() / 2, c.bottom() + 1 - d.handle->height());
                d.handle->raise();
            }
            d.handle->setVisible(shown);
        }
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
