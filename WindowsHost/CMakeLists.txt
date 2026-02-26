cmake_minimum_required(VERSION 3.20)
project(SideScreen VERSION 0.5.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Qt 6
find_package(Qt6 REQUIRED COMPONENTS Widgets Network)

# NVIDIA Video Codec SDK (optional)
set(NVCODEC_SDK_DIR "" CACHE PATH "Path to NVIDIA Video Codec SDK")
if(EXISTS "${NVCODEC_SDK_DIR}/Interface/nvEncodeAPI.h")
    set(HAS_NVENC TRUE)
    add_definitions(-DHAS_NVENC)
    message(STATUS "NVENC SDK found at ${NVCODEC_SDK_DIR}")
else()
    set(HAS_NVENC FALSE)
    message(STATUS "NVENC SDK not found, NVENC encoder disabled")
endif()

# AMF SDK (optional)
set(AMF_SDK_DIR "" CACHE PATH "Path to AMD AMF SDK")
if(EXISTS "${AMF_SDK_DIR}/amf/public/include/core/Factory.h")
    set(HAS_AMF TRUE)
    add_definitions(-DHAS_AMF)
    message(STATUS "AMF SDK found at ${AMF_SDK_DIR}")
else()
    set(HAS_AMF FALSE)
    message(STATUS "AMF SDK not found, AMF encoder disabled")
endif()

# Source files
set(SOURCES
    src/main.cpp
    src/AppController.cpp
    src/AdbManager.cpp
    src/streaming/StreamingServer.cpp
    src/capture/ScreenCapture.cpp
    src/encoder/VideoEncoder.cpp
    src/encoder/NvencEncoder.cpp
    src/encoder/AmfEncoder.cpp
    src/encoder/QsvEncoder.cpp
    src/encoder/MfSoftEncoder.cpp
    src/display/VirtualDisplayManager.cpp
    src/input/TouchHandler.cpp
    src/ui/SettingsWindow.cpp
    src/ui/DisplaySettings.cpp
)

set(HEADERS
    src/Config.h
    src/AppController.h
    src/AdbManager.h
    src/streaming/StreamingServer.h
    src/capture/ScreenCapture.h
    src/encoder/VideoEncoder.h
    src/encoder/NvencEncoder.h
    src/encoder/AmfEncoder.h
    src/encoder/QsvEncoder.h
    src/encoder/MfSoftEncoder.h
    src/display/VirtualDisplayManager.h
    src/input/TouchHandler.h
    src/ui/SettingsWindow.h
    src/ui/DisplaySettings.h
)

# Main executable
add_executable(SideScreen WIN32 ${SOURCES} ${HEADERS})

target_include_directories(SideScreen PRIVATE
    ${CMAKE_SOURCE_DIR}/src
)

if(HAS_NVENC)
    target_include_directories(SideScreen PRIVATE ${NVCODEC_SDK_DIR}/Interface)
endif()

if(HAS_AMF)
    target_include_directories(SideScreen PRIVATE ${AMF_SDK_DIR})
endif()

# Platform libraries
target_link_libraries(SideScreen PRIVATE
    Qt6::Widgets
    Qt6::Network
    d3d11
    dxgi
    ws2_32
    user32
    gdi32
    ole32
    setupapi
    mfplat
    mfuuid
    mf
    mfreadwrite
)

# Tests (optional)
option(BUILD_TESTS "Build tests" OFF)
if(BUILD_TESTS)
    enable_testing()
    find_package(GTest REQUIRED)

    add_executable(test_streaming_server tests/test_streaming_server.cpp src/streaming/StreamingServer.cpp)
    target_include_directories(test_streaming_server PRIVATE src)
    target_link_libraries(test_streaming_server PRIVATE GTest::GTest GTest::Main ws2_32)
    add_test(NAME StreamingServerTest COMMAND test_streaming_server)

    add_executable(test_touch_handler tests/test_touch_handler.cpp src/input/TouchHandler.cpp)
    target_include_directories(test_touch_handler PRIVATE src)
    target_link_libraries(test_touch_handler PRIVATE GTest::GTest GTest::Main user32)
    add_test(NAME TouchHandlerTest COMMAND test_touch_handler)
endif()
