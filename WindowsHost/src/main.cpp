#include <QApplication>
#include <QMessageBox>
#include <QSystemTrayIcon>
#include "Config.h"
#include "AppController.h"

int main(int argc, char* argv[]) {
    QApplication app(argc, argv);
    app.setApplicationName(Config::APP_NAME);
    app.setApplicationVersion(Config::APP_VERSION);
    app.setQuitOnLastWindowClosed(false);

    if (!QSystemTrayIcon::isSystemTrayAvailable()) {
        QMessageBox::critical(nullptr, Config::APP_NAME,
            "System tray is not available on this system.");
        return 1;
    }

    AppController controller;
    controller.initialize();

    return app.exec();
}
