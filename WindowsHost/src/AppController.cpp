#include "AppController.h"
#include <QApplication>
#include <QMessageBox>
#include <QStyle>
#include <thread>
#include <chrono>

AppController::AppController(QObject* parent) : QObject(parent) {}

AppController::~AppController() {
    stopServer();
    delete settingsWindow_;
}

void AppController::initialize() {
    setupTrayIcon();

    settingsWindow_ = new SettingsWindow(settings_);
    connect(settingsWindow_, &SettingsWindow::settingsChanged,
            this, &AppController::onSettingsChanged);
    connect(settingsWindow_, &SettingsWindow::startRequested,
            this, &AppController::startServer);
    connect(settingsWindow_, &SettingsWindow::stopRequested,
            this, &AppController::stopServer);

    // Stats timer — update UI every second
    statsTimer_ = new QTimer(this);
    connect(statsTimer_, &QTimer::timeout, this, &AppController::updateTrayTooltip);

    showSettings();
}

void AppController::setupTrayIcon() {
    trayIcon_ = new QSystemTrayIcon(this);
    trayIcon_->setIcon(QApplication::style()->standardIcon(QStyle::SP_ComputerIcon));
    trayIcon_->setToolTip("SideScreen — Stopped");

    trayMenu_ = new QMenu();

    statusAction_ = trayMenu_->addAction("Status: Stopped");
    statusAction_->setEnabled(false);

    trayMenu_->addSeparator();

    startStopAction_ = trayMenu_->addAction("Start Server");
    connect(startStopAction_, &QAction::triggered, this, [this]() {
        if (isRunning_) stopServer(); else startServer();
    });

    auto* settingsAction = trayMenu_->addAction("Settings...");
    connect(settingsAction, &QAction::triggered, this, &AppController::showSettings);

    trayMenu_->addSeparator();

    auto* quitAction = trayMenu_->addAction("Quit");
    connect(quitAction, &QAction::triggered, qApp, &QApplication::quit);

    trayIcon_->setContextMenu(trayMenu_);

    connect(trayIcon_, &QSystemTrayIcon::activated, this,
            [this](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::DoubleClick) showSettings();
    });

    trayIcon_->show();
}

void AppController::showSettings() {
    if (settingsWindow_) {
        settingsWindow_->show();
        settingsWindow_->raise();
        settingsWindow_->activateWindow();
    }
}

void AppController::startServer() {
    if (isRunning_) return;

    printf("[App] Starting server...\n");

    // 1. Setup ADB reverse
    std::string adbPath = adbManager_.findAdb();
    if (!adbPath.empty()) {
        printf("[App] ADB found at: %s\n", adbPath.c_str());
        if (adbManager_.isDeviceConnected()) {
            adbManager_.setupReverse(static_cast<uint16_t>(settings_.port));
            printf("[App] ADB reverse port forwarding set up\n");
        } else {
            printf("[App] No Android device connected via USB\n");
        }
    } else {
        printf("[App] ADB not found — USB connection may not work\n");
    }

    // 2. Create virtual display
    displayManager_ = std::make_unique<VirtualDisplayManager>();
    bool displayOk = displayManager_->createDisplay(
        settings_.width(), settings_.height(), settings_.effectiveRefreshRate());

    if (!displayOk) {
        printf("[App] WARNING: Virtual display creation failed. "
               "Will capture primary monitor instead.\n");
    } else {
        printf("[App] Virtual display created: %dx%d @ %dHz\n",
               settings_.width(), settings_.height(), settings_.effectiveRefreshRate());

        // Wait for display to initialize (same as macOS 500ms delay)
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        displayManager_->restorePosition();
    }

    // 3. Initialize screen capture
    capture_ = std::make_unique<ScreenCapture>();
    bool captureOk = false;

    if (displayOk && displayManager_->monitorHandle()) {
        captureOk = capture_->initializeForDisplay(displayManager_->monitorHandle());
    }
    if (!captureOk) {
        // Fallback to primary monitor
        captureOk = capture_->initialize(0);
    }

    if (!captureOk) {
        QMessageBox::critical(nullptr, "SideScreen",
            "Failed to initialize screen capture.\n"
            "Make sure you have a compatible GPU.");
        stopServer();
        return;
    }

    printf("[App] Screen capture initialized: %dx%d\n",
           capture_->width(), capture_->height());

    // 4. Create encoder
    encoder_ = VideoEncoder::create(
        capture_->device(),
        capture_->width(), capture_->height(),
        settings_.effectiveRefreshRate(),
        settings_.effectiveBitrate());

    if (!encoder_) {
        QMessageBox::critical(nullptr, "SideScreen",
            "Failed to create H.265 encoder.\n"
            "No compatible GPU encoder found (NVENC/AMF/QuickSync).");
        stopServer();
        return;
    }

    printf("[App] Encoder created: %s\n", encoder_->encoderName().c_str());

    // 5. Create streaming server
    server_ = std::make_unique<StreamingServer>(
        static_cast<uint16_t>(settings_.port));
    server_->setDisplaySize(
        capture_->width(), capture_->height(), settings_.rotation);

    // 6. Create touch handler
    touchHandler_ = std::make_unique<TouchHandler>();

    // 7. Wire pipeline
    connectPipeline();

    // 8. Start components
    capture_->startCapture(settings_.effectiveRefreshRate());

    if (!server_->start()) {
        QMessageBox::critical(nullptr, "SideScreen",
            QString("Failed to start server on port %1.\n"
                    "Port may be in use.").arg(settings_.port));
        stopServer();
        return;
    }

    isRunning_ = true;
    startStopAction_->setText("Stop Server");
    statusAction_->setText("Status: Running");
    trayIcon_->setToolTip("SideScreen — Running");
    statsTimer_->start(1000);

    // Update settings window
    if (settingsWindow_) {
        settingsWindow_->updateStatus(
            displayOk, false,
            QString::fromStdString(encoder_->encoderName()));
    }

    printf("[App] Server started on port %d\n", settings_.port);
}

void AppController::stopServer() {
    if (!isRunning_ && !server_ && !capture_ && !encoder_) return;

    printf("[App] Stopping server...\n");

    statsTimer_->stop();

    // Stop in reverse order
    if (server_) server_->stop();
    if (capture_) capture_->stop();

    disconnectPipeline();

    if (displayManager_ && displayManager_->isDisplayCreated()) {
        displayManager_->savePosition();
        displayManager_->destroyDisplay();
    }

    // Release resources
    server_.reset();
    encoder_.reset();
    capture_.reset();
    touchHandler_.reset();
    displayManager_.reset();

    // Clean up ADB reverse
    adbManager_.removeReverse(static_cast<uint16_t>(settings_.port));

    isRunning_ = false;
    startStopAction_->setText("Start Server");
    statusAction_->setText("Status: Stopped");
    trayIcon_->setToolTip("SideScreen — Stopped");

    if (settingsWindow_) {
        settingsWindow_->updateStatus(false, false, "");
        settingsWindow_->updateStats(0, 0, 0);
    }

    printf("[App] Server stopped\n");
}

void AppController::connectPipeline() {
    if (!capture_ || !encoder_ || !server_) return;

    // Capture → Encoder
    capture_->setFrameCallback(
        [this](ID3D11Texture2D* texture, uint64_t timestampNs) {
            if (encoder_) {
                encoder_->encode(texture, timestampNs);
            }
        });

    // Encoder → Server
    encoder_->setOutputCallback(
        [this](const uint8_t* data, size_t size, uint64_t timestampNs, bool isKeyframe) {
            if (server_) {
                server_->sendFrame(data, size);
            }
        });

    // Server → Touch Handler
    server_->setTouchCallback(
        [this](int count, float x1, float y1, float x2, float y2, int action) {
            if (touchHandler_ && settings_.touchEnabled) {
                touchHandler_->handleTouch(count, x1, y1, x2, y2, action);
            }
        });

    // Server → UI (connection status)
    server_->setConnectionCallback(
        [this](bool connected) {
            QMetaObject::invokeMethod(this, [this, connected]() {
                if (settingsWindow_) {
                    settingsWindow_->updateStatus(
                        displayManager_ && displayManager_->isDisplayCreated(),
                        connected,
                        encoder_ ? QString::fromStdString(encoder_->encoderName()) : "");
                }

                // Update touch handler bounds when client connects
                if (connected && touchHandler_ && displayManager_) {
                    // Get display bounds for coordinate mapping
                    RECT bounds = {};
                    MONITORINFO mi = { sizeof(mi) };
                    if (displayManager_->monitorHandle() &&
                        GetMonitorInfoW(displayManager_->monitorHandle(), &mi)) {
                        bounds = mi.rcMonitor;
                    }
                    touchHandler_->setDisplayBounds(
                        bounds.left, bounds.top,
                        bounds.right - bounds.left,
                        bounds.bottom - bounds.top);
                }

                printf("[App] Client %s\n", connected ? "connected" : "disconnected");
            });
        });

    // Server → Stats
    server_->setStatsCallback(
        [this](double fps, double mbps) {
            QMetaObject::invokeMethod(this, [this, fps, mbps]() {
                if (settingsWindow_) {
                    settingsWindow_->updateStats(fps, mbps, 0);
                }
            });
        });
}

void AppController::disconnectPipeline() {
    if (capture_) capture_->setFrameCallback(nullptr);
    if (encoder_) encoder_->setOutputCallback(nullptr);
    if (server_) {
        server_->setTouchCallback(nullptr);
        server_->setConnectionCallback(nullptr);
        server_->setStatsCallback(nullptr);
    }
}

void AppController::onSettingsChanged() {
    if (!isRunning_) return;

    // Update encoder settings on the fly
    if (encoder_) {
        encoder_->updateSettings(
            settings_.effectiveBitrate(),
            settings_.effectiveQualityValue(),
            settings_.gamingBoost);
    }

    // Update rotation
    if (server_) {
        server_->updateRotation(settings_.rotation);
    }

    printf("[App] Settings updated: %d Mbps, quality=%.2f, gaming=%d\n",
           settings_.effectiveBitrate(),
           settings_.effectiveQualityValue(),
           settings_.gamingBoost);
}

void AppController::updateTrayTooltip() {
    if (!isRunning_) return;

    bool connected = server_ && server_->isClientConnected();
    QString tooltip = QString("SideScreen — %1")
        .arg(connected ? "Streaming" : "Waiting for client");
    trayIcon_->setToolTip(tooltip);
}
