#pragma once
#include <cstdint>
#include <string>

namespace Config {
    // App info
    constexpr const char* APP_NAME = "SideScreen";
    constexpr const char* APP_VERSION = "0.5.2";

    // Network
    constexpr uint16_t DEFAULT_PORT = 8888;

    // Display defaults
    constexpr int DEFAULT_WIDTH = 1920;
    constexpr int DEFAULT_HEIGHT = 1200;
    constexpr int DEFAULT_REFRESH_RATE = 120;

    // Streaming defaults
    constexpr int DEFAULT_BITRATE_MBPS = 1000;
    constexpr int MIN_BITRATE_MBPS = 20;
    constexpr int MAX_BITRATE_MBPS = 5000;

    // Quality presets (encoder quality parameter)
    constexpr float QUALITY_ULTRALOW = 0.5f;
    constexpr float QUALITY_LOW = 0.65f;
    constexpr float QUALITY_MEDIUM = 0.8f;
    constexpr float QUALITY_HIGH = 0.9f;

    // Gaming Boost overrides
    constexpr int GAMING_BOOST_BITRATE = 1000;
    constexpr int GAMING_BOOST_REFRESH = 120;
    constexpr float GAMING_BOOST_QUALITY = 0.3f;

    // Protocol message types
    constexpr uint8_t MSG_VIDEO_FRAME = 0;
    constexpr uint8_t MSG_DISPLAY_CONFIG = 1;
    constexpr uint8_t MSG_TOUCH_EVENT = 2;
    constexpr uint8_t MSG_PING = 4;
    constexpr uint8_t MSG_PONG = 5;

    // Limits
    constexpr int MAX_FRAME_SIZE = 5 * 1024 * 1024; // 5MB
    constexpr int ENCODER_QUEUE_DEPTH = 2;
    constexpr int CAPTURE_QUEUE_DEPTH = 4;

    // Gesture thresholds (matching macOS)
    constexpr float TAP_MAX_DISTANCE = 15.0f;
    constexpr int TAP_MAX_TIME_MS = 250;
    constexpr int DOUBLE_TAP_MAX_TIME_MS = 400;
    constexpr float DOUBLE_TAP_MAX_DISTANCE = 20.0f;
    constexpr int LONG_PRESS_TIME_MS = 500;
    constexpr float SCROLL_SENSITIVITY = 1.2f;
    constexpr float PINCH_MIN_DISTANCE = 20.0f;
    constexpr float MOMENTUM_DECAY = 0.92f;
    constexpr float MOMENTUM_MIN_VELOCITY = 0.5f;
    constexpr int MOMENTUM_INTERVAL_MS = 16; // ~60Hz

    // Virtual display
    constexpr uint32_t DISPLAY_VENDOR_ID = 0xEEEE;
    constexpr uint32_t DISPLAY_PRODUCT_BASE = 0xEEEE;
    constexpr float DISPLAY_PPI = 110.0f;
}
