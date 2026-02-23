#pragma once

#include <cstdint>
#include <functional>
#include <atomic>
#include <mutex>
#include <thread>
#include <chrono>

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>

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
    // Server lifecycle
    bool createListenSocket();
    void acceptLoop();
    void handleClient(int clientSocket);
    void receiveLoop();
    void closeClient();

    // Protocol
    void sendDisplayConfig();
    void sendPong(const uint8_t* timestampData);

    // Stats
    void updateStats(size_t bytes);

    // Helpers
    static bool sendAll(int sock, const uint8_t* data, size_t size);
    static bool recvAll(int sock, uint8_t* data, size_t size);

    // Network state
    uint16_t m_port;
    int m_listenSocket = -1;
    int m_clientSocket = -1;
    std::mutex m_clientMutex;  // Protects m_clientSocket access
    std::mutex m_sendMutex;    // Serializes frame sends from encoder thread

    // Threads
    std::thread m_acceptThread;
    std::thread m_receiveThread;

    // Lifecycle
    std::atomic<bool> m_running{false};
    std::atomic<bool> m_clientConnected{false};

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
