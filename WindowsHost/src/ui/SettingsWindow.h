#pragma once
#include <QWidget>
#include <QComboBox>
#include <QSlider>
#include <QLabel>
#include <QCheckBox>
#include <QSpinBox>
#include <QRadioButton>
#include <QButtonGroup>
#include <QPushButton>
#include <QGroupBox>
#include "DisplaySettings.h"

class SettingsWindow : public QWidget {
    Q_OBJECT

public:
    explicit SettingsWindow(DisplaySettings& settings, QWidget* parent = nullptr);

    void updateStatus(bool displayCreated, bool clientConnected,
                      const QString& encoderName);
    void updateStats(double fps, double mbps, double latencyMs);

signals:
    void settingsChanged();
    void startRequested();
    void stopRequested();

private slots:
    void onResolutionChanged();
    void onRefreshRateChanged();
    void onBitrateChanged(int value);
    void onQualityChanged();
    void onGamingBoostChanged(bool checked);
    void onPortChanged(int value);
    void onRotationChanged();
    void onStartStopClicked();

private:
    void setupUI();
    QGroupBox* createDisplayGroup();
    QGroupBox* createStreamingGroup();
    QGroupBox* createNetworkGroup();
    QGroupBox* createStatusGroup();
    void loadFromSettings();
    void applyToSettings();

    DisplaySettings& settings_;

    // Display controls
    QComboBox* resolutionCombo_ = nullptr;
    QButtonGroup* fpsGroup_ = nullptr;
    QRadioButton* fps30_ = nullptr;
    QRadioButton* fps60_ = nullptr;
    QRadioButton* fps90_ = nullptr;
    QRadioButton* fps120_ = nullptr;
    QComboBox* rotationCombo_ = nullptr;

    // Streaming controls
    QSlider* bitrateSlider_ = nullptr;
    QLabel* bitrateLabel_ = nullptr;
    QComboBox* qualityCombo_ = nullptr;
    QCheckBox* gamingBoostCheck_ = nullptr;

    // Network controls
    QSpinBox* portSpin_ = nullptr;

    // Status
    QLabel* statusDisplay_ = nullptr;
    QLabel* statusClient_ = nullptr;
    QLabel* statusEncoder_ = nullptr;
    QLabel* statsFps_ = nullptr;
    QLabel* statsBitrate_ = nullptr;
    QLabel* statsLatency_ = nullptr;
    QPushButton* startStopBtn_ = nullptr;

    bool isRunning_ = false;
};
