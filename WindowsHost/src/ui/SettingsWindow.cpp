#include "SettingsWindow.h"
#include "../Config.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QFormLayout>
#include <QFont>
#include <QString>

SettingsWindow::SettingsWindow(DisplaySettings& settings, QWidget* parent)
    : QWidget(parent), settings_(settings)
{
    setupUI();
    loadFromSettings();
    setWindowTitle("SideScreen Settings");
    setFixedSize(480, 780);
    setWindowFlags(Qt::Window | Qt::WindowCloseButtonHint | Qt::WindowMinimizeButtonHint);
}

void SettingsWindow::setupUI() {
    auto* mainLayout = new QVBoxLayout(this);
    mainLayout->setSpacing(12);
    mainLayout->setContentsMargins(16, 16, 16, 16);

    // Title
    auto* titleLabel = new QLabel("SideScreen");
    titleLabel->setAlignment(Qt::AlignCenter);
    QFont titleFont = titleLabel->font();
    titleFont.setPointSize(18);
    titleFont.setBold(true);
    titleLabel->setFont(titleFont);
    mainLayout->addWidget(titleLabel);

    auto* subtitleLabel = new QLabel("Windows Host");
    subtitleLabel->setAlignment(Qt::AlignCenter);
    QFont subFont = subtitleLabel->font();
    subFont.setPointSize(10);
    subtitleLabel->setFont(subFont);
    subtitleLabel->setStyleSheet("color: gray;");
    mainLayout->addWidget(subtitleLabel);

    mainLayout->addSpacing(8);
    mainLayout->addWidget(createStatusGroup());
    mainLayout->addWidget(createDisplayGroup());
    mainLayout->addWidget(createStreamingGroup());
    mainLayout->addWidget(createNetworkGroup());

    // Start/Stop button
    startStopBtn_ = new QPushButton("Start Server");
    startStopBtn_->setMinimumHeight(40);
    startStopBtn_->setStyleSheet(
        "QPushButton { background-color: #0078D4; color: white; border-radius: 6px; font-size: 14px; }"
        "QPushButton:hover { background-color: #106EBE; }"
        "QPushButton:pressed { background-color: #005A9E; }"
    );
    connect(startStopBtn_, &QPushButton::clicked, this, &SettingsWindow::onStartStopClicked);
    mainLayout->addWidget(startStopBtn_);

    mainLayout->addStretch();
}

QGroupBox* SettingsWindow::createDisplayGroup() {
    auto* group = new QGroupBox("Display");
    auto* layout = new QFormLayout(group);

    // Resolution
    resolutionCombo_ = new QComboBox();
    auto resGroups = DisplaySettings::availableResolutions();
    for (const auto& rg : resGroups) {
        resolutionCombo_->addItem(
            QString("── %1 ──").arg(QString::fromStdString(rg.name)));
        // Make separator non-selectable
        auto* model = qobject_cast<QStandardItemModel*>(resolutionCombo_->model());
        if (model) {
            auto* item = model->item(model->rowCount() - 1);
            item->setFlags(item->flags() & ~Qt::ItemIsSelectable & ~Qt::ItemIsEnabled);
        }
        for (const auto& [w, h] : rg.resolutions) {
            resolutionCombo_->addItem(
                QString("%1x%2").arg(w).arg(h),
                QString("%1x%2").arg(w).arg(h));
        }
    }
    connect(resolutionCombo_, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &SettingsWindow::onResolutionChanged);
    layout->addRow("Resolution:", resolutionCombo_);

    // Frame rate
    auto* fpsLayout = new QHBoxLayout();
    fpsGroup_ = new QButtonGroup(this);
    fps30_ = new QRadioButton("30");
    fps60_ = new QRadioButton("60");
    fps90_ = new QRadioButton("90");
    fps120_ = new QRadioButton("120");
    fpsGroup_->addButton(fps30_, 30);
    fpsGroup_->addButton(fps60_, 60);
    fpsGroup_->addButton(fps90_, 90);
    fpsGroup_->addButton(fps120_, 120);
    fpsLayout->addWidget(fps30_);
    fpsLayout->addWidget(fps60_);
    fpsLayout->addWidget(fps90_);
    fpsLayout->addWidget(fps120_);
    fpsLayout->addWidget(new QLabel("FPS"));
    connect(fpsGroup_, QOverload<int>::of(&QButtonGroup::idClicked),
            this, [this](int) { onRefreshRateChanged(); });
    layout->addRow("Frame Rate:", fpsLayout);

    // Rotation
    rotationCombo_ = new QComboBox();
    rotationCombo_->addItem("0° (Landscape)", 0);
    rotationCombo_->addItem("90° (Portrait)", 90);
    rotationCombo_->addItem("180° (Landscape Flipped)", 180);
    rotationCombo_->addItem("270° (Portrait Flipped)", 270);
    connect(rotationCombo_, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &SettingsWindow::onRotationChanged);
    layout->addRow("Rotation:", rotationCombo_);

    return group;
}

QGroupBox* SettingsWindow::createStreamingGroup() {
    auto* group = new QGroupBox("Streaming");
    auto* layout = new QFormLayout(group);

    // Bitrate slider
    auto* bitrateLayout = new QHBoxLayout();
    bitrateSlider_ = new QSlider(Qt::Horizontal);
    bitrateSlider_->setRange(Config::MIN_BITRATE_MBPS, Config::MAX_BITRATE_MBPS);
    bitrateSlider_->setSingleStep(10);
    bitrateLabel_ = new QLabel("1000 Mbps");
    bitrateLabel_->setMinimumWidth(80);
    connect(bitrateSlider_, &QSlider::valueChanged, this, &SettingsWindow::onBitrateChanged);
    bitrateLayout->addWidget(bitrateSlider_);
    bitrateLayout->addWidget(bitrateLabel_);
    layout->addRow("Bitrate:", bitrateLayout);

    // Quality
    qualityCombo_ = new QComboBox();
    qualityCombo_->addItem("Ultra Low (Fast)", "ultralow");
    qualityCombo_->addItem("Low (Balanced)", "low");
    qualityCombo_->addItem("Medium (Sharp)", "medium");
    qualityCombo_->addItem("High (Very Sharp)", "high");
    connect(qualityCombo_, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &SettingsWindow::onQualityChanged);
    layout->addRow("Quality:", qualityCombo_);

    // Gaming Boost
    gamingBoostCheck_ = new QCheckBox("Gaming Boost (1 Gbps, 120Hz, Ultra-Low Latency)");
    gamingBoostCheck_->setToolTip("Optimizes for competitive gaming with maximum performance");
    connect(gamingBoostCheck_, &QCheckBox::toggled, this, &SettingsWindow::onGamingBoostChanged);
    layout->addRow("", gamingBoostCheck_);

    return group;
}

QGroupBox* SettingsWindow::createNetworkGroup() {
    auto* group = new QGroupBox("Network");
    auto* layout = new QFormLayout(group);

    portSpin_ = new QSpinBox();
    portSpin_->setRange(1024, 65535);
    portSpin_->setValue(Config::DEFAULT_PORT);
    connect(portSpin_, QOverload<int>::of(&QSpinBox::valueChanged),
            this, &SettingsWindow::onPortChanged);
    layout->addRow("Port:", portSpin_);

    return group;
}

QGroupBox* SettingsWindow::createStatusGroup() {
    auto* group = new QGroupBox("Status");
    auto* layout = new QFormLayout(group);

    statusDisplay_ = new QLabel("Not Created");
    statusClient_ = new QLabel("Not Connected");
    statusEncoder_ = new QLabel("—");
    statsFps_ = new QLabel("—");
    statsBitrate_ = new QLabel("—");
    statsLatency_ = new QLabel("—");

    layout->addRow("Display:", statusDisplay_);
    layout->addRow("Client:", statusClient_);
    layout->addRow("Encoder:", statusEncoder_);
    layout->addRow("FPS:", statsFps_);
    layout->addRow("Bitrate:", statsBitrate_);
    layout->addRow("Latency:", statsLatency_);

    return group;
}

void SettingsWindow::loadFromSettings() {
    // Resolution
    QString resStr = QString::fromStdString(settings_.resolution);
    for (int i = 0; i < resolutionCombo_->count(); ++i) {
        if (resolutionCombo_->itemData(i).toString() == resStr) {
            resolutionCombo_->setCurrentIndex(i);
            break;
        }
    }

    // FPS
    if (auto* btn = fpsGroup_->button(settings_.refreshRate))
        btn->setChecked(true);

    // Rotation
    for (int i = 0; i < rotationCombo_->count(); ++i) {
        if (rotationCombo_->itemData(i).toInt() == settings_.rotation) {
            rotationCombo_->setCurrentIndex(i);
            break;
        }
    }

    // Streaming
    bitrateSlider_->setValue(settings_.bitrate);
    onBitrateChanged(settings_.bitrate);

    QString qualStr = QString::fromStdString(settings_.quality);
    for (int i = 0; i < qualityCombo_->count(); ++i) {
        if (qualityCombo_->itemData(i).toString() == qualStr) {
            qualityCombo_->setCurrentIndex(i);
            break;
        }
    }

    gamingBoostCheck_->setChecked(settings_.gamingBoost);

    // Network
    portSpin_->setValue(settings_.port);
}

void SettingsWindow::applyToSettings() {
    settings_.save();
    emit settingsChanged();
}

void SettingsWindow::onResolutionChanged() {
    QString data = resolutionCombo_->currentData().toString();
    if (!data.isEmpty()) {
        settings_.resolution = data.toStdString();
        applyToSettings();
    }
}

void SettingsWindow::onRefreshRateChanged() {
    settings_.refreshRate = fpsGroup_->checkedId();
    applyToSettings();
}

void SettingsWindow::onBitrateChanged(int value) {
    settings_.bitrate = value;
    bitrateLabel_->setText(QString("%1 Mbps").arg(value));
    applyToSettings();
}

void SettingsWindow::onQualityChanged() {
    QString data = qualityCombo_->currentData().toString();
    if (!data.isEmpty()) {
        settings_.quality = data.toStdString();
        applyToSettings();
    }
}

void SettingsWindow::onGamingBoostChanged(bool checked) {
    settings_.gamingBoost = checked;

    // Disable controls when gaming boost is on
    bitrateSlider_->setEnabled(!checked);
    qualityCombo_->setEnabled(!checked);
    fps120_->setChecked(checked);
    fpsGroup_->setExclusive(!checked);
    for (auto* btn : fpsGroup_->buttons())
        btn->setEnabled(!checked);

    if (checked) {
        bitrateSlider_->setValue(Config::GAMING_BOOST_BITRATE);
        bitrateLabel_->setText(QString("%1 Mbps (Gaming)").arg(Config::GAMING_BOOST_BITRATE));
    }

    applyToSettings();
}

void SettingsWindow::onPortChanged(int value) {
    settings_.port = value;
    applyToSettings();
}

void SettingsWindow::onRotationChanged() {
    settings_.rotation = rotationCombo_->currentData().toInt();
    applyToSettings();
}

void SettingsWindow::onStartStopClicked() {
    if (isRunning_) {
        isRunning_ = false;
        startStopBtn_->setText("Start Server");
        startStopBtn_->setStyleSheet(
            "QPushButton { background-color: #0078D4; color: white; border-radius: 6px; font-size: 14px; }"
            "QPushButton:hover { background-color: #106EBE; }"
        );
        emit stopRequested();
    } else {
        isRunning_ = true;
        startStopBtn_->setText("Stop Server");
        startStopBtn_->setStyleSheet(
            "QPushButton { background-color: #D83B01; color: white; border-radius: 6px; font-size: 14px; }"
            "QPushButton:hover { background-color: #B83200; }"
        );
        emit startRequested();
    }
}

void SettingsWindow::updateStatus(bool displayCreated, bool clientConnected,
                                   const QString& encoderName) {
    statusDisplay_->setText(displayCreated ? "Created" : "Not Created");
    statusDisplay_->setStyleSheet(displayCreated ? "color: green;" : "color: gray;");

    statusClient_->setText(clientConnected ? "Connected" : "Not Connected");
    statusClient_->setStyleSheet(clientConnected ? "color: green;" : "color: gray;");

    statusEncoder_->setText(encoderName.isEmpty() ? "—" : encoderName);
}

void SettingsWindow::updateStats(double fps, double mbps, double latencyMs) {
    statsFps_->setText(QString::number(fps, 'f', 1));
    statsBitrate_->setText(QString("%1 Mbps").arg(mbps, 0, 'f', 1));
    statsLatency_->setText(latencyMs > 0 ? QString("%1 ms").arg(latencyMs, 0, 'f', 1) : "—");
}
