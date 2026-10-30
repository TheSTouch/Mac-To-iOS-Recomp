// Light and dark mode for desktop Qt apps on iOS. The app follows the device's mode (or the
// one its profile's "appearance" pins in the Info.plist, recomp/qt_ios.py), live.
//
// Qt's iOS theme gives the application a palette that is only half dark in dark mode: it
// starts from Fusion's palette for the scheme Qt saw when it started (before UIKit had a
// window: light) and sets iOS's colours on the Active group's text roles only. Inactive and
// disabled text stay Fusion's light colours, black and light gray, so any widget drawn as
// inactive (item views often are) shows black text on a black window. Its UIKit colours are
// also resolved for whatever trait collection is current, so after a live switch some roles
// keep the old mode's. So the application palette here is built whole, every role in every
// group, from iOS's system colours resolved for the scheme Qt reports, at start-up and on
// each change, and passed on to widgets under a style sheet, which keep the old one
// otherwise (refresh()). Inactive is Active: iOS has no inactive windows. An app that sets
// its own application palette keeps it.
//
// Test hook: an empty `recomp-appearance` file in Documents logs the colour scheme, the
// application palette and, for every visible widget that draws text, its palette group's
// text and background colours.
#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QTimer>
#include <QtGui/QGuiApplication>
#include <QtGui/QStyleHints>
#include <QtWidgets/QAbstractButton>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QApplication>
#include <QtWidgets/QLabel>
#include <QtWidgets/QStyle>
#include <QtWidgets/QWidget>

#import <UIKit/UIKit.h>

namespace {

QPalette applied;      // the application palette set here last
bool appOwns = false;  // the app set its own: leave it

QColor resolved(UIColor *color, UITraitCollection *traits)
{
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [[color resolvedColorWithTraitCollection:traits] getRed:&r green:&g blue:&b alpha:&a];
    return QColor::fromRgbF(float(r), float(g), float(b), float(a));
}

QPalette schemePalette(bool dark)
{
    UITraitCollection *traits =
        [UITraitCollection traitCollectionWithUserInterfaceStyle:dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight];
    // The roles Qt's iOS theme takes from UIKit, the rest derived the way Fusion does.
    const QColor window = resolved(UIColor.systemGroupedBackgroundColor, traits);
    const QColor base = resolved(UIColor.secondarySystemGroupedBackgroundColor, traits);
    const QColor button = resolved(UIColor.secondarySystemBackgroundColor, traits);
    const QColor text = resolved(UIColor.labelColor, traits);
    const QColor disabledText = dark ? QColor(130, 130, 130) : QColor(190, 190, 190);
    const QColor dimmed = button.darker(130);

    QPalette p(text, button, button.lighter(150), button.darker(150), dimmed, text, resolved(UIColor.lightTextColor, traits),
               base, window);
    p.setColor(QPalette::Midlight, dimmed.lighter(110));
    p.setColor(QPalette::Shadow, button.darker(150).darker(135));
    p.setColor(QPalette::AlternateBase, resolved(UIColor.tertiarySystemGroupedBackgroundColor, traits));
    p.setColor(QPalette::ToolTipBase, button);
    p.setColor(QPalette::ToolTipText, text);
    p.setColor(QPalette::PlaceholderText, resolved(UIColor.placeholderTextColor, traits));
    p.setColor(QPalette::Link, resolved(UIColor.linkColor, traits));
    p.setColor(QPalette::LinkVisited, resolved(UIColor.linkColor, traits));
    p.setColor(QPalette::Highlight, QColor(11, 70, 150, dark ? 140 : 60));
    p.setColor(QPalette::HighlightedText, text);
    for (QPalette::ColorRole role : {QPalette::WindowText, QPalette::Text, QPalette::ButtonText})
        p.setColor(QPalette::Disabled, role, disabledText);
    p.setColor(QPalette::Disabled, QPalette::Base, window);
    p.setColor(QPalette::Disabled, QPalette::Highlight, QColor(145, 145, 145));
    return p;
}

// Widgets under a style sheet miss a new application palette two ways. Qt does not pass a
// parent's palette on to them (QWidgetPrivate::propagatePaletteChange skips
// WA_StyleSheet children): each resolves its own on the change event, which may come
// before its parent's, so it keeps the parent's old colours. And one the sheet gives
// colours holds a copy of the whole palette it had when it was polished
// (QStyleSheetStyle::setPalette). So, parents first, the first resolve again and the
// second are polished again, which copies the new palette.
void refresh(QWidget *w)
{
    QStyle *style = w->style();
    if (style->inherits("QStyleSheetStyle")) {
        if (w->testAttribute(Qt::WA_SetPalette)) {
            style->unpolish(w);
            style->polish(w);
        } else {
            QEvent change(QEvent::ApplicationPaletteChange);
            QCoreApplication::sendEvent(w, &change);
        }
    }
    for (QObject *child : w->children())
        if (child->isWidgetType() && !static_cast<QWidget *>(child)->isWindow())
            refresh(static_cast<QWidget *>(child));
}

void apply()
{
    if (appOwns)
        return;
    // Ours, or the theme's (no role set): anything else the app set itself.
    const QPalette now = QGuiApplication::palette();
    if (QCoreApplication::testAttribute(Qt::AA_SetPalette) && !(now == applied && now.resolveMask() == applied.resolveMask())) {
        appOwns = true;
        fprintf(stderr, "[recomp] appearance: the app sets its own palette, kept\n");
        return;
    }
    const bool dark = QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
    applied = schemePalette(dark);
    QApplication::setPalette(applied);
    applied = QGuiApplication::palette();
    for (QWidget *top : QApplication::topLevelWidgets())
        refresh(top);
    fprintf(stderr, "[recomp] appearance: %s palette\n", dark ? "dark" : "light");
}

QString name(const QColor &c)
{
    return c.name(QColor::HexArgb);
}

void logPalette(const char *what, const QPalette &p)
{
    static const char *groups[] = {"active", "disabled", "inactive"};
    for (int g = 0; g < 3; ++g) {
        const auto cg = QPalette::ColorGroup(g);
        fprintf(stderr, "[recomp] %s %s: window %s text %s, base %s text %s, button %s text %s\n", what, groups[g],
                qPrintable(name(p.color(cg, QPalette::Window))), qPrintable(name(p.color(cg, QPalette::WindowText))),
                qPrintable(name(p.color(cg, QPalette::Base))), qPrintable(name(p.color(cg, QPalette::Text))),
                qPrintable(name(p.color(cg, QPalette::Button))), qPrintable(name(p.color(cg, QPalette::ButtonText))));
    }
}

void logAppearance()
{
    fprintf(stderr, "[recomp] colour scheme %s%s\n",
            QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark ? "dark" : "light",
            appOwns ? ", the app's own palette" : "");
    logPalette("application", QGuiApplication::palette());
    for (QWidget *w : QApplication::allWidgets()) {
        if (!w->isVisible())
            continue;
        QPalette::ColorRole fg, bg;
        if (qobject_cast<QAbstractItemView *>(w))
            fg = QPalette::Text, bg = QPalette::Base;
        else if (qobject_cast<QAbstractButton *>(w))
            fg = QPalette::ButtonText, bg = QPalette::Button;
        else if (qobject_cast<QLabel *>(w))
            fg = QPalette::WindowText, bg = QPalette::Window;
        else
            continue;
        const QPalette p = w->palette();
        const QPalette::ColorGroup cg = !w->isEnabled() ? QPalette::Disabled
                                        : w->isActiveWindow() ? QPalette::Active : QPalette::Inactive;
        fprintf(stderr, "[recomp]   %s \"%s\" %s: %s on %s%s%s\n", w->metaObject()->className(),
                qPrintable(w->objectName()), cg == QPalette::Active ? "active" : cg == QPalette::Inactive ? "inactive" : "disabled",
                qPrintable(name(p.color(cg, fg))), qPrintable(name(p.color(cg, bg))),
                w->testAttribute(Qt::WA_SetPalette) ? ", own palette" : "",
                w->styleSheet().isEmpty() ? "" : ", style sheet");
    }
}

void startAppearance()
{
    if (!qobject_cast<QApplication *>(QCoreApplication::instance()))
        return;
    // Qt emits the change after it has updated its own palette for the new scheme.
    QObject::connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, qApp, [] { apply(); });
    QMetaObject::invokeMethod(qApp, [] {
        apply();
        QTimer *timer = new QTimer(qApp);
        QObject::connect(timer, &QTimer::timeout, qApp, [] {
            QFile request(QDir::homePath() + QStringLiteral("/Documents/recomp-appearance"));
            if (!request.exists())
                return;
            request.remove();
            logAppearance();
        });
        timer->start(1000);
    }, Qt::QueuedConnection);
}

}

Q_COREAPP_STARTUP_FUNCTION(startAppearance)
