#pragma once

#include <QObject>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QTimer>
#include <memory>

#include "Config.h"
#include "streaming/StreamingServer.h"
#include "capture/ScreenCapture.h"
#include "encoder/VideoEncoder.h"
#include "display/VirtualDisplayManager.h"
#include "input/TouchHandler.h"
#include "ui/SettingsWindow.h"
#include "ui/DisplaySettings.h"

class AppController : public QObject {
    Q_OBJECT

public:
    explicit AppController(QObject* parent = nullptr);
    ~AppController();

    void initialize();

public slots:
    void startServer();
    void stopServer();
    void onSettingsChanged();
    void showSettings();

private:
    void setupTrayIcon();
    void connectPipeline();
    void disconnectPipeline();
    void updateTrayTooltip();

    // ADB helpers (inline — no separate AdbManager on Linux, uses popen)
    std::string findAdb();
    bool adbSetupReverse(uint16_t port);
    bool adbRemoveReverse(uint16_t port);
    bool adbIsDeviceConnected();

    // Pipeline components
    std::unique_ptr<VirtualDisplayManager> displayManager_;
    std::unique_ptr<ScreenCapture> capture_;
    std::unique_ptr<VideoEncoder> encoder_;
    std::unique_ptr<StreamingServer> server_;
    std::unique_ptr<TouchHandler> touchHandler_;

    // UI
    QSystemTrayIcon* trayIcon_ = nullptr;
    QMenu* trayMenu_ = nullptr;
    QAction* startStopAction_ = nullptr;
    QAction* statusAction_ = nullptr;
    SettingsWindow* settingsWindow_ = nullptr;
    DisplaySettings settings_;

    // Stats timer
    QTimer* statsTimer_ = nullptr;

    // State
    bool isRunning_ = false;
    std::string adbPath_;
};
