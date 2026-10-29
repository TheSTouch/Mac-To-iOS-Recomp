// Window sizes for desktop Qt apps on iOS. The screen decides how big a window
// is (Qt's iOS plugin keeps main windows maximized and other windows on screen,
// recomp/patches/qt-<version>-ios.patch), but a QWidget window's layout makes its
// minimum size the sum of its contents (a main window with a few docks open is
// wider than an 11-inch iPad) and grows the window back to it. So top-level
// windows' layouts stop enforcing their minimum, and the contents squeeze in.
#include <QtCore/QCoreApplication>
#include <QtWidgets/QApplication>
#include <QtWidgets/QLayout>
#include <QtGui/QScreen>
#include <QtWidgets/QWidget>

namespace {

class WindowFitter : public QObject
{
public:
    using QObject::QObject;

    bool eventFilter(QObject *object, QEvent *event) override
    {
        // Polish comes before the first show, while the window has no size yet.
        if ((event->type() == QEvent::Polish || event->type() == QEvent::Show) && object->isWidgetType()) {
            QWidget *w = static_cast<QWidget *>(object);
            const Qt::WindowType type = w->windowType();
            if (w->isWindow() && type != Qt::Popup && type != Qt::ToolTip && type != Qt::SplashScreen)
                unconstrain(w);
        }
        return false;
    }

    static void unconstrain(QWidget *w)
    {
        QLayout *layout = w->layout();
        if (layout && layout->sizeConstraint() != QLayout::SetNoConstraint
            && layout->sizeConstraint() != QLayout::SetFixedSize)
            layout->setSizeConstraint(QLayout::SetNoConstraint);
        if (w->minimumSize() != QSize(0, 0))
            w->setMinimumSize(0, 0);
        // Already grown past the screen: back to what the screen allows.
        if (w->isVisible() && w->screen()) {
            const QRect available = w->screen()->availableGeometry();
            if (w->width() > available.width() || w->height() > available.height()) {
                if (w->windowType() == Qt::Window)
                    w->setGeometry(available);
                else
                    w->resize(w->size().boundedTo(available.size()));
            }
        }
    }
};

void startWindowFitter()
{
    if (qobject_cast<QApplication *>(QCoreApplication::instance()))
        qApp->installEventFilter(new WindowFitter(qApp));
}

}

Q_COREAPP_STARTUP_FUNCTION(startWindowFitter)
