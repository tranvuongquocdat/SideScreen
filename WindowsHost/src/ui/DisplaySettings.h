#pragma once
#include <string>
#include <vector>
#include <QSettings>

struct ResolutionGroup {
    std::string name;
    std::vector<std::pair<int, int>> resolutions;
};

class DisplaySettings {
public:
    DisplaySettings();

    // Display
    std::string resolution = "1920x1200";
    int refreshRate = 120;
    int rotation = 0;
    bool hiDPI = false;

    // Streaming
    int bitrate = 1000;          // Mbps
    std::string quality = "ultralow"; // ultralow/low/medium/high
    bool gamingBoost = false;

    // Network
    int port = 8888;

    // Touch
    bool touchEnabled = true;

    // Effective values (respecting Gaming Boost)
    int effectiveBitrate() const { return gamingBoost ? 1000 : bitrate; }
    std::string effectiveQuality() const { return gamingBoost ? "ultralow" : quality; }
    int effectiveRefreshRate() const { return gamingBoost ? 120 : refreshRate; }

    // Parse resolution string
    int width() const;
    int height() const;

    // Quality float value
    float qualityValue() const;
    float effectiveQualityValue() const;

    // Persistence
    void save();
    void load();

    // Available resolutions (matching macOS)
    static std::vector<ResolutionGroup> availableResolutions();
};
