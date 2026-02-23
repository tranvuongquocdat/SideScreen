cmake_minimum_required(VERSION 3.20)
project(SideScreen VERSION 0.5.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Qt 6
find_package(Qt6 REQUIRED COMPONENTS Widgets Network)

# PipeWire (for screen capture on Wayland)
find_package(PkgConfig REQUIRED)
pkg_check_modules(PIPEWIRE libpipewire-0.3)
if(PIPEWIRE_FOUND)
    find_package(Qt6 REQUIRED COMPONENTS DBus)
    add_definitions(-DHAS_PIPEWIRE)
    message(STATUS "PipeWire found (with Qt6::DBus for portal)")
else()
    message(STATUS "PipeWire not found, PipeWire capture disabled")
endif()

# VA-API (for hardware video encoding)
pkg_check_modules(VAAPI libva libva-drm)
if(VAAPI_FOUND)
    add_definitions(-DHAS_VAAPI)
    message(STATUS "VA-API found")
else()
    message(STATUS "VA-API not found, VA-API encoder disabled")
endif()

# FFmpeg (for encoding fallback and VA-API integration)
pkg_check_modules(AVCODEC libavcodec)
pkg_check_modules(AVUTIL libavutil)
pkg_check_modules(SWSCALE libswscale)
if(AVCODEC_FOUND AND AVUTIL_FOUND)
    add_definitions(-DHAS_FFMPEG)
    message(STATUS "FFmpeg found")
else()
    message(STATUS "FFmpeg not found, FFmpeg encoder disabled")
endif()

# X11 (for X11 capture and xdotool input)
pkg_check_modules(X11 x11 xext xrandr xcomposite xfixes)
if(X11_FOUND)
    add_definitions(-DHAS_X11)
    message(STATUS "X11 found")
else()
    message(STATUS "X11 not found")
endif()

# libxdo (for touch input injection)
pkg_check_modules(XDO libxdo)
if(XDO_FOUND)
    add_definitions(-DHAS_XDO)
    message(STATUS "libxdo found")
else()
    message(STATUS "libxdo not found, will use xdotool CLI")
endif()

# Source files
set(SOURCES
    src/main.cpp
    src/AppController.cpp
    src/streaming/StreamingServer.cpp
    src/capture/ScreenCapture.cpp
    src/capture/PipeWireCapture.cpp
    src/capture/X11Capture.cpp
    src/encoder/VideoEncoder.cpp
    src/encoder/VaapiEncoder.cpp
    src/encoder/FFmpegEncoder.cpp
    src/display/VirtualDisplayManager.cpp
    src/input/TouchHandler.cpp
    src/ui/SettingsWindow.cpp
    src/ui/DisplaySettings.cpp
)

set(HEADERS
    src/Config.h
    src/AppController.h
    src/streaming/StreamingServer.h
    src/capture/ScreenCapture.h
    src/capture/PipeWireCapture.h
    src/capture/X11Capture.h
    src/encoder/VideoEncoder.h
    src/encoder/VaapiEncoder.h
    src/encoder/FFmpegEncoder.h
    src/display/VirtualDisplayManager.h
    src/input/TouchHandler.h
    src/ui/SettingsWindow.h
    src/ui/DisplaySettings.h
)

add_executable(SideScreen ${SOURCES} ${HEADERS})

target_include_directories(SideScreen PRIVATE
    ${CMAKE_SOURCE_DIR}/src
)

target_link_libraries(SideScreen PRIVATE
    Qt6::Widgets
    Qt6::Network
    pthread
)

if(PIPEWIRE_FOUND)
    target_include_directories(SideScreen PRIVATE ${PIPEWIRE_INCLUDE_DIRS})
    target_link_libraries(SideScreen PRIVATE ${PIPEWIRE_LIBRARIES} Qt6::DBus)
endif()

if(VAAPI_FOUND)
    target_include_directories(SideScreen PRIVATE ${VAAPI_INCLUDE_DIRS})
    target_link_libraries(SideScreen PRIVATE ${VAAPI_LIBRARIES})
endif()

if(AVCODEC_FOUND AND AVUTIL_FOUND)
    target_include_directories(SideScreen PRIVATE
        ${AVCODEC_INCLUDE_DIRS} ${AVUTIL_INCLUDE_DIRS})
    target_link_libraries(SideScreen PRIVATE
        ${AVCODEC_LIBRARIES} ${AVUTIL_LIBRARIES})
    if(SWSCALE_FOUND)
        target_include_directories(SideScreen PRIVATE ${SWSCALE_INCLUDE_DIRS})
        target_link_libraries(SideScreen PRIVATE ${SWSCALE_LIBRARIES})
    endif()
endif()

if(X11_FOUND)
    target_include_directories(SideScreen PRIVATE ${X11_INCLUDE_DIRS})
    target_link_libraries(SideScreen PRIVATE ${X11_LIBRARIES})
endif()

if(XDO_FOUND)
    target_include_directories(SideScreen PRIVATE ${XDO_INCLUDE_DIRS})
    target_link_libraries(SideScreen PRIVATE ${XDO_LIBRARIES})
endif()

# Install
install(TARGETS SideScreen DESTINATION bin)
install(FILES resources/sidescreen.desktop DESTINATION share/applications OPTIONAL)
install(FILES resources/sidescreen.png DESTINATION share/icons/hicolor/256x256/apps OPTIONAL)
