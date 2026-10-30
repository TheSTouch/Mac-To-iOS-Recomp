// Text input for desktop Qt apps on iOS. Qt's iOS plugin brings the keyboard up for a tap
// only when the tap lands on the focused input (recomp/patches/qt-<version>-ios.patch), and
// it learns where the input is from its answer to Qt::ImInputItemClipRectangle. QWidget
// answers with its visible rectangle, but a widget that overrides inputMethodQuery() and
// returns nothing for queries it does not know (QScintilla does) has an empty one: no tap
// ever lands on it, its text responder never takes the keys, and a hardware keyboard types
// nothing there. Such a widget is given QWidget's answer here.
//
// Test hook: an empty `recomp-input` file in Documents logs the focus object, whether it
// takes text, its input rectangle and UIKit's first responder (Qt's text responder while
// the keys go to the input).
#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QTimer>
#include <QtGui/QInputMethod>
#include <QtGui/QInputMethodQueryEvent>
#include <QtWidgets/QApplication>
#include <QtWidgets/QWidget>

#import <UIKit/UIKit.h>
#include <objc/runtime.h>

static UIResponder *recompFirstResponder;

@interface UIResponder (RecompQtInput)
- (void)recomp_findFirstResponder:(id)sender;
@end

@implementation UIResponder (RecompQtInput)
- (void)recomp_findFirstResponder:(id)sender
{
    recompFirstResponder = self;
}
@end

namespace {

class InputRectangle : public QObject
{
public:
    using QObject::QObject;

    bool eventFilter(QObject *object, QEvent *event) override
    {
        if (event->type() != QEvent::InputMethodQuery || object == answering || !object->isWidgetType())
            return false;
        auto *query = static_cast<QInputMethodQueryEvent *>(event);
        if (!(query->queries() & Qt::ImInputItemClipRectangle))
            return false;
        // The widget answers first, through its own event filters too; this filter
        // skips that nested delivery.
        QObject *outer = answering;
        answering = object;
        QCoreApplication::sendEvent(object, event);
        answering = outer;
        if (!query->value(Qt::ImInputItemClipRectangle).isValid()
            && static_cast<QWidget *>(object)->testAttribute(Qt::WA_InputMethodEnabled))
            query->setValue(Qt::ImInputItemClipRectangle, visibleRect(static_cast<QWidget *>(object)));
        return true;
    }

private:
    // QWidget's answer (QWidgetPrivate::clipRect()): its rectangle clipped by its parents,
    // in its own coordinates.
    static QRect visibleRect(const QWidget *w)
    {
        QRect r = w->rect();
        QPoint offset;
        for (const QWidget *child = w; !child->isWindow() && child->parentWidget(); child = child->parentWidget()) {
            offset -= child->pos();
            r &= child->parentWidget()->rect().translated(offset);
        }
        return r;
    }

    QObject *answering = nullptr;
};

void logInput()
{
    QObject *focus = QGuiApplication::focusObject();
    QInputMethodQueryEvent query(Qt::ImEnabled | Qt::ImInputItemClipRectangle | Qt::ImCursorRectangle);
    if (focus)
        QCoreApplication::sendEvent(focus, &query);
    const QRect clip = query.value(Qt::ImInputItemClipRectangle).toRect();
    const QRect cursor = query.value(Qt::ImCursorRectangle).toRect();
    // The widget's own answer, past the filter above.
    QInputMethodQueryEvent own(Qt::ImInputItemClipRectangle);
    if (focus)
        focus->event(&own);
    const bool answers = own.value(Qt::ImInputItemClipRectangle).isValid();
    // What the iOS plugin compares taps with: the input rectangle in window coordinates.
    const QRectF inWindow = QGuiApplication::inputMethod()->inputItemClipRectangle();
    recompFirstResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(recomp_findFirstResponder:) to:nil from:nil forEvent:nil];
    fprintf(stderr, "[recomp] input: focus %s \"%s\", text %d, input rect %d,%d %dx%d%s, cursor %d,%d %dx%d, "
                    "in the window %.0f,%.0f %.0fx%.0f; first responder %s\n",
            focus ? focus->metaObject()->className() : "none", focus ? qPrintable(focus->objectName()) : "",
            query.value(Qt::ImEnabled).toBool(), clip.x(), clip.y(), clip.width(), clip.height(),
            answers ? "" : " (given here, the widget has none)",
            cursor.x(), cursor.y(), cursor.width(), cursor.height(),
            inWindow.x(), inWindow.y(), inWindow.width(), inWindow.height(),
            recompFirstResponder ? class_getName([recompFirstResponder class]) : "none");
}

void startInput()
{
    if (!qobject_cast<QApplication *>(QCoreApplication::instance()))
        return;
    qApp->installEventFilter(new InputRectangle(qApp));
    QMetaObject::invokeMethod(qApp, [] {
        QTimer *timer = new QTimer(qApp);
        QObject::connect(timer, &QTimer::timeout, qApp, [] {
            QFile request(QDir::homePath() + QStringLiteral("/Documents/recomp-input"));
            if (!request.exists())
                return;
            request.remove();
            logInput();
        });
        timer->start(1000);
    }, Qt::QueuedConnection);
}

}

Q_COREAPP_STARTUP_FUNCTION(startInput)
