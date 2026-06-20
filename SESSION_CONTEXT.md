# Session Context

## Current Objective
Enhancing the macOS SideScreen host app by adding "Launch at Login" functionality and improving the Settings UI. 
Implementing https://github.com/tranvuongquocdat/SideScreen/issues/24 and adding explanations for Mac app settings.

## Work Accomplished
- Resolved macOS strict code signing issues (-67028) with `SMAppService.agent` by reverting back to `SMAppService.mainApp` to leverage the standard Login Items mechanism.
- Improved the auto-start background experience: Updated `AppDelegate.swift` to launch silently in the background when "Launch at Login" is enabled, without showing the Settings window immediately. 
- Implemented `applicationShouldHandleReopen` so the user can easily open the Settings UI by clicking the app icon in the Dock or Applications folder even when running invisibly.
- Refactored the `SettingsWindow.swift` layout to use a Tabbed interface (Display & Input, Connection, Quality, Status) rather than a continuous scroll.
- Added 2-3 sentence descriptive sub-labels for every configuration setting (Resolution, Frame Rate, Rotation, Port, Bitrate) to explain their purpose and impact to the user.

## Next Steps
- Implement Hybrid Standby Mode / Wireless enhancement where a connected tablet can smoothly resume without manual toggles.
