#pragma once

#include <cstdint>
#include <functional>
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>

#include "../Config.h"

class StreamingServer {
public:
    // Callback types
    using TouchCallback = std::function<void(int pointerCount, float x1, float y1,
                                             float x2, float y2, int action)>;
    using ConnectionCallback = std::function<void(bool connected)>;
    using StatsCallback = std::function<void(double fps, double mbps)>;

    explicit StreamingServer(uint16_t port = Config::DEFAULT_PORT);
    ~StreamingServer();

    // Non-copyable, non-movable
    StreamingServer(const StreamingServer&) = delete;
    StreamingServer& operator=(const StreamingServer&) = delete;

    bool start();
    void stop();

    void setDisplaySize(int width, int height, int rotation = 0);
    void updateRotation(int rotation);

    // Thread-safe: may be called from encoder thread
    void sendFrame(const uint8_t* data, size_t size);

    void setTouchCallback(TouchCallback callback);
    void setConnectionCallback(ConnectionCallback callback);
    void setStatsCallback(StatsCallback callback);

    bool isClientConnected() const;

private:
    // Winsock initialization
    bool initWinsock();
    void cleanupWinsock();

    // Server lifecycle
    bool createListenSocket();
    void acceptLoop();
    void handleClient(SOCKET clientSocket);
    void receiveLoop();
    void closeClient();

    // Protocol
    void sendDisplayConfig();
    void sendPong(const uint8_t* timestampData);

    // Stats
    void updateStats(size_t bytes);

    // Helpers
    static bool sendAll(SOCKET sock, const uint8_t* data, size_t size);
    static bool recvAll(SOCKET sock, uint8_t* data, size_t size);

    // Network state
    uint16_t m_port;
    SOCKET m_listenSocket = INVALID_SOCKET;
    SOCKET m_clientSocket = INVALID_SOCKET;
    std::mutex m_clientMutex;  // Protects m_clientSocket access
    std::mutex m_sendMutex;    // Serializes frame sends from encoder thread

    // Threads
    std::thread m_acceptThread;
    std::thread m_receiveThread;

    // Lifecycle
    std::atomic<bool> m_running{false};
    std::atomic<bool> m_clientConnected{false};
    bool m_wsaInitialized = false;

    // Display config (protected by m_displayMutex)
    std::mutex m_displayMutex;
    int m_displayWidth = Config::DEFAULT_WIDTH;
    int m_displayHeight = Config::DEFAULT_HEIGHT;
    int m_rotation = 0;

    // Callbacks
    TouchCallback m_touchCallback;
    ConnectionCallback m_connectionCallback;
    StatsCallback m_statsCallback;

    // Stats tracking
    std::mutex m_statsMutex;
    uint64_t m_bytesSent = 0;
    uint64_t m_frameCount = 0;
    std::chrono::steady_clock::time_point m_lastStatsTime;
};
