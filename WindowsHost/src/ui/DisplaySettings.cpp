#include "DisplaySettings.h"
#include "../Config.h"
#include <sstream>

DisplaySettings::DisplaySettings() {
    load();
}

int DisplaySettings::width() const {
    auto pos = resolution.find('x');
    if (pos == std::string::npos) return Config::DEFAULT_WIDTH;
    return std::stoi(resolution.substr(0, pos));
}

int DisplaySettings::height() const {
    auto pos = resolution.find('x');
    if (pos == std::string::npos) return Config::DEFAULT_HEIGHT;
    return std::stoi(resolution.substr(pos + 1));
}

float DisplaySettings::qualityValue() const {
    if (quality == "ultralow") return Config::QUALITY_ULTRALOW;
    if (quality == "low")      return Config::QUALITY_LOW;
    if (quality == "medium")   return Config::QUALITY_MEDIUM;
    if (quality == "high")     return Config::QUALITY_HIGH;
    return Config::QUALITY_ULTRALOW;
}

float DisplaySettings::effectiveQualityValue() const {
    if (gamingBoost) return Config::GAMING_BOOST_QUALITY;
    return qualityValue();
}

void DisplaySettings::save() {
    QSettings s("SideScreen", "SideScreen");
    s.setValue("resolution", QString::fromStdString(resolution));
    s.setValue("refreshRate", refreshRate);
    s.setValue("rotation", rotation);
    s.setValue("hiDPI", hiDPI);
    s.setValue("bitrate", bitrate);
    s.setValue("quality", QString::fromStdString(quality));
    s.setValue("gamingBoost", gamingBoost);
    s.setValue("port", port);
    s.setValue("touchEnabled", touchEnabled);
}

void DisplaySettings::load() {
    QSettings s("SideScreen", "SideScreen");
    resolution = s.value("resolution", "1920x1200").toString().toStdString();
    refreshRate = s.value("refreshRate", 120).toInt();
    rotation = s.value("rotation", 0).toInt();
    hiDPI = s.value("hiDPI", false).toBool();
    bitrate = s.value("bitrate", 1000).toInt();
    quality = s.value("quality", "ultralow").toString().toStdString();
    gamingBoost = s.value("gamingBoost", false).toBool();
    port = s.value("port", 8888).toInt();
    touchEnabled = s.value("touchEnabled", true).toBool();
}

std::vector<ResolutionGroup> DisplaySettings::availableResolutions() {
    return {
        {"16:10 (Widescreen)", {
            {1280, 800}, {1440, 900}, {1680, 1050}, {1920, 1200}, {2560, 1600}
        }},
        {"16:9 (HD/4K)", {
            {1280, 720}, {1366, 768}, {1600, 900}, {1920, 1080}, {2560, 1440}, {3840, 2160}
        }},
        {"4:3 (Classic)", {
            {1024, 768}, {1280, 960}, {1600, 1200}
        }},
        {"3:2 (Surface/Pixel)", {
            {1920, 1280}, {2160, 1440}, {2736, 1824}
        }},
        {"5:3 (Tablet Wide)", {
            {2000, 1200}, {2560, 1536}, {2800, 1680}
        }},
        {"4:3 (iPad)", {
            {2048, 1536}, {2224, 1668}, {2388, 1668}, {2732, 2048}
        }}
    };
}
