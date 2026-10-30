// Test hooks for Qt ports, driven by files in the app's Documents folder (copied
// there with `xcrun simctl` or `devicectl device copy to --domain-type appDataContainer`):
//
//   recomp-actions   (empty)          -> recomp-actions.txt: every QAction, "objectName<TAB>text"
//   recomp-action    "objectName"     -> triggers that action (its text works too)
//   recomp-text      (empty)          -> recomp-text.txt: the text of every visible text view
//   recomp-type      "text"           -> types that text into the focused widget (or the first visible
//                                        widget that takes input methods), as a keyboard would commit it
//   recomp-click     "x y"            -> a left click (press, release; not a touch) at that point of
//                                        the screen, in points, sent to the widget under it
//   recomp-grab      (empty)          -> recomp-gl-<n>.png: what each QOpenGLWidget rendered, read back
//                                        from its framebuffer, and recomp-window.png: the window
//
// Each request file is deleted once handled. Checked once a second from Qt's event loop.
#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QStandardPaths>
#include <QtCore/QTimer>
#include <QtGui/QAction>
#include <QtGui/QImage>
#include <QtGui/QInputMethodEvent>
#include <QtGui/QScreen>
#include <QtGui/QMouseEvent>
#include <QtGui/QOpenGLContext>
#include <QtGui/QOpenGLFunctions>
#include <QtOpenGLWidgets/QOpenGLWidget>
#include <QtWidgets/QApplication>
#include <QtWidgets/QPlainTextEdit>
#include <QtWidgets/QTextEdit>
#include <QtWidgets/QWidget>

static QList<QAction *> allActions()
{
    QList<QAction *> out;
    for (QWidget *w : QApplication::allWidgets())
        for (QAction *a : w->findChildren<QAction *>())
            if (!out.contains(a))
                out.append(a);
    return out;
}

static void poll()
{
    const QString docs = QDir::homePath() + QStringLiteral("/Documents/");
    QFile list(docs + QStringLiteral("recomp-actions"));
    if (list.exists()) {
        list.remove();
        QFile out(docs + QStringLiteral("recomp-actions.txt"));
        if (out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            for (QAction *a : allActions())
                out.write((a->objectName() + QLatin1Char('\t') + a->text() + QLatin1Char('\n')).toUtf8());
        }
        fprintf(stderr, "[recomp] wrote recomp-actions.txt\n");
    }
    QFile text(docs + QStringLiteral("recomp-text"));
    if (text.exists()) {
        text.remove();
        QFile out(docs + QStringLiteral("recomp-text.txt"));
        if (out.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            for (QWidget *w : QApplication::allWidgets()) {
                QString body;
                if (auto *e = qobject_cast<QTextEdit *>(w))
                    body = e->toPlainText();
                else if (auto *p = qobject_cast<QPlainTextEdit *>(w))
                    body = p->toPlainText();
                if (w->isVisible() && !body.isEmpty())
                    out.write(("== " + w->objectName() + " (" + w->metaObject()->className() + ")\n" + body
                               + "\n").toUtf8());
            }
        }
        fprintf(stderr, "[recomp] wrote recomp-text.txt\n");
    }
    QFile type(docs + QStringLiteral("recomp-type"));
    if (type.exists() && type.open(QIODevice::ReadOnly)) {
        const QString body = QString::fromUtf8(type.readAll());
        type.close();
        type.remove();
        QWidget *target = QApplication::focusWidget();
        for (QWidget *w : QApplication::allWidgets()) {
            if (target)
                break;
            if (w->isVisible() && w->testAttribute(Qt::WA_InputMethodEnabled))
                target = w;
        }
        if (target) {
            QInputMethodEvent event;
            event.setCommitString(body);
            QApplication::sendEvent(target, &event);
            fprintf(stderr, "[recomp] typed %d characters into %s\n", int(body.size()), target->metaObject()->className());
        } else {
            fprintf(stderr, "[recomp] nothing to type into\n");
        }
    }
    QFile click(docs + QStringLiteral("recomp-click"));
    if (click.exists() && click.open(QIODevice::ReadOnly)) {
        const QStringList xy = QString::fromUtf8(click.readAll()).split(QLatin1Char(' '), Qt::SkipEmptyParts);
        click.close();
        click.remove();
        const QPoint global(xy.value(0).toInt(), xy.value(1).toInt());
        if (QWidget *w = QApplication::widgetAt(global)) {
            const QPointF local = w->mapFromGlobal(QPointF(global));
            QMouseEvent press(QEvent::MouseButtonPress, local, QPointF(global), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
            QMouseEvent release(QEvent::MouseButtonRelease, local, QPointF(global), Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
            QApplication::sendEvent(w, &press);
            QApplication::sendEvent(w, &release);
            fprintf(stderr, "[recomp] clicked %s at %d,%d (local %g,%g)\n", w->metaObject()->className(), global.x(),
                    global.y(), local.x(), local.y());
        }
    }
    QFile grab(docs + QStringLiteral("recomp-grab"));
    if (grab.exists()) {
        grab.remove();
        int n = 0;
        for (QWidget *w : QApplication::allWidgets()) {
            if (auto *gl = qobject_cast<QOpenGLWidget *>(w)) {
                QImage image = gl->grabFramebuffer();
                gl->makeCurrent();
                GLint depth = -1, stencil = -1;
                QOpenGLContext::currentContext()->functions()->glGetIntegerv(GL_DEPTH_BITS, &depth);
                QOpenGLContext::currentContext()->functions()->glGetIntegerv(GL_STENCIL_BITS, &stencil);
                gl->doneCurrent();
                fprintf(stderr, "[recomp] %s framebuffer: depth %d bits, stencil %d bits (format asks %d, %d)\n",
                        gl->metaObject()->className(), depth, stencil, gl->format().depthBufferSize(),
                        gl->format().stencilBufferSize());
                image.save(docs + QStringLiteral("recomp-gl-%1.png").arg(n++));
                fprintf(stderr, "[recomp] grabbed %s %dx%d\n", gl->metaObject()->className(), image.width(),
                        image.height());
            }
        }
        if (QWidget *top = QApplication::activeWindow()) {
            top->grab().save(docs + QStringLiteral("recomp-window.png"));
            const QRect screen = top->screen() ? top->screen()->availableGeometry() : QRect();
            fprintf(stderr, "[recomp] window %s %dx%d+%d+%d, minimum %dx%d; screen available %dx%d+%d+%d\n",
                    top->metaObject()->className(), top->width(), top->height(), top->x(), top->y(),
                    top->minimumWidth(), top->minimumHeight(), screen.width(), screen.height(), screen.x(), screen.y());
        }
    }
    QFile request(docs + QStringLiteral("recomp-action"));
    if (request.exists() && request.open(QIODevice::ReadOnly)) {
        const QString name = QString::fromUtf8(request.readAll()).trimmed();
        request.close();
        request.remove();
        for (QAction *a : allActions()) {
            if (a->objectName() == name || a->text().remove(QLatin1Char('&')) == name) {
                fprintf(stderr, "[recomp] triggering %s\n", qPrintable(name));
                a->trigger();
                return;
            }
        }
        fprintf(stderr, "[recomp] no action named %s\n", qPrintable(name));
    }
}

static void startHooks()
{
    if (!qobject_cast<QApplication *>(QCoreApplication::instance()))
        return;
    // Startup functions run before the platform plugin exists, so no timer yet:
    // a queued call starts it once the event loop runs.
    QMetaObject::invokeMethod(QCoreApplication::instance(), [] {
        QTimer *timer = new QTimer(QCoreApplication::instance());
        QObject::connect(timer, &QTimer::timeout, poll);
        timer->start(1000);
    }, Qt::QueuedConnection);
}
Q_COREAPP_STARTUP_FUNCTION(startHooks)
