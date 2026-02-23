#include "StreamingServer.h"
#include <cstring>
#include <cstdio>
#include <cerrno>

// ============================================================================
// Byte-order helpers
// ============================================================================

// Write a 32-bit integer in Big-Endian
static void writeBE32(uint8_t* dst, int32_t value) {
    uint32_t v = static_cast<uint32_t>(value);
    dst[0] = static_cast<uint8_t>((v >> 24) & 0xFF);
    dst[1] = static_cast<uint8_t>((v >> 16) & 0xFF);
    dst[2] = static_cast<uint8_t>((v >> 8)  & 0xFF);
    dst[3] = static_cast<uint8_t>((v)       & 0xFF);
}

// Read a float from Little-Endian bytes (assumes host is LE — x86/ARM)
static float readLEFloat(const uint8_t* src) {
    float val;
    std::memcpy(&val, src, sizeof(float));
    return val;
}

// Read a 32-bit int from Little-Endian bytes
static int32_t readLE32(const uint8_t* src) {
    int32_t val;
    std::memcpy(&val, src, sizeof(int32_t));
    return val;
}

// ============================================================================
// Construction / Destruction
// ============================================================================

StreamingServer::StreamingServer(uint16_t port)
    : m_port(port)
    , m_lastStatsTime(std::chrono::steady_clock::now())
{
}

StreamingServer::~StreamingServer() {
    stop();
}

// ============================================================================
// Public API
// ============================================================================

bool StreamingServer::start() {
    if (m_running.load()) {
        return true; // Already running
    }

    if (!createListenSocket()) {
        return false;
    }

    m_running.store(true);
    m_lastStatsTime = std::chrono::steady_clock::now();

    // Start accept thread
    m_acceptThread = std::thread(&StreamingServer::acceptLoop, this);

    printf("[StreamingServer] Listening on port %u\n", m_port);
    return true;
}

void StreamingServer::stop() {
    if (!m_running.exchange(false)) {
        return; // Was already stopped
    }

    // Close listening socket to unblock accept()
    if (m_listenSocket != -1) {
        ::shutdown(m_listenSocket, SHUT_RDWR);
        ::close(m_listenSocket);
        m_listenSocket = -1;
    }

    // Close client connection
    closeClient();

    // Wait for threads to finish
    if (m_acceptThread.joinable()) {
        m_acceptThread.join();
    }
    if (m_receiveThread.joinable()) {
        m_receiveThread.join();
    }

    printf("[StreamingServer] Stopped\n");
}

void StreamingServer::setDisplaySize(int width, int height, int rotation) {
    std::lock_guard<std::mutex> lock(m_displayMutex);
    m_displayWidth = width;
    m_displayHeight = height;
    m_rotation = rotation;
}

void StreamingServer::updateRotation(int rotation) {
    {
        std::lock_guard<std::mutex> lock(m_displayMutex);
        m_rotation = rotation;
    }
    // Re-send display config to connected client
    sendDisplayConfig();
}

void StreamingServer::sendFrame(const uint8_t* data, size_t size) {
    if (!m_clientConnected.load() || data == nullptr || size == 0) {
        return;
    }

    if (size > static_cast<size_t>(Config::MAX_FRAME_SIZE)) {
        printf("[StreamingServer] Frame too large: %zu bytes (max %d)\n",
               size, Config::MAX_FRAME_SIZE);
        return;
    }

    // Build packet: [0x00][4B size BE][N bytes data]
    // Header: 1 byte type + 4 bytes size = 5 bytes
    uint8_t header[5];
    header[0] = Config::MSG_VIDEO_FRAME;
    writeBE32(header + 1, static_cast<int32_t>(size));

    // Serialize sends from potentially concurrent encoder threads
    std::lock_guard<std::mutex> lock(m_sendMutex);

    int sock;
    {
        std::lock_guard<std::mutex> clientLock(m_clientMutex);
        sock = m_clientSocket;
    }

    if (sock == -1) {
        return;
    }

    // Send header + payload
    if (!sendAll(sock, header, sizeof(header)) ||
        !sendAll(sock, data, size)) {
        // Send failed, client likely disconnected
        m_clientConnected.store(false);
        return;
    }

    updateStats(size);
}

void StreamingServer::setTouchCallback(TouchCallback callback) {
    m_touchCallback = std::move(callback);
}

void StreamingServer::setConnectionCallback(ConnectionCallback callback) {
    m_connectionCallback = std::move(callback);
}

void StreamingServer::setStatsCallback(StatsCallback callback) {
    m_statsCallback = std::move(callback);
}

bool StreamingServer::isClientConnected() const {
    return m_clientConnected.load();
}

// ============================================================================
// Socket setup
// ============================================================================

bool StreamingServer::createListenSocket() {
    m_listenSocket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (m_listenSocket == -1) {
        printf("[StreamingServer] socket() failed: %s\n", strerror(errno));
        return false;
    }

    // Allow address reuse
    int optval = 1;
    setsockopt(m_listenSocket, SOL_SOCKET, SO_REUSEADDR,
               &optval, sizeof(optval));

    // Bind
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(m_port);

    if (::bind(m_listenSocket, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == -1) {
        printf("[StreamingServer] bind() failed: %s\n", strerror(errno));
        ::close(m_listenSocket);
        m_listenSocket = -1;
        return false;
    }

    // Listen with backlog of 1 (single client)
    if (::listen(m_listenSocket, 1) == -1) {
        printf("[StreamingServer] listen() failed: %s\n", strerror(errno));
        ::close(m_listenSocket);
        m_listenSocket = -1;
        return false;
    }

    return true;
}

// ============================================================================
// Accept loop
// ============================================================================

void StreamingServer::acceptLoop() {
    while (m_running.load()) {
        sockaddr_in clientAddr{};
        socklen_t addrLen = sizeof(clientAddr);

        int newClient = ::accept(m_listenSocket,
                                 reinterpret_cast<sockaddr*>(&clientAddr),
                                 &addrLen);

        if (newClient == -1) {
            if (!m_running.load()) {
                break; // Server is shutting down
            }
            printf("[StreamingServer] accept() failed: %s\n", strerror(errno));
            continue;
        }

        // Log client address
        char addrStr[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &clientAddr.sin_addr, addrStr, sizeof(addrStr));
        printf("[StreamingServer] Client connected from %s:%u\n",
               addrStr, ntohs(clientAddr.sin_port));

        handleClient(newClient);
    }
}

void StreamingServer::handleClient(int clientSocket) {
    // Close any existing client connection
    closeClient();

    // Wait for receive thread from previous client to finish
    if (m_receiveThread.joinable()) {
        m_receiveThread.join();
    }

    // Set TCP_NODELAY on the new connection
    int optval = 1;
    setsockopt(clientSocket, IPPROTO_TCP, TCP_NODELAY,
               &optval, sizeof(optval));

    // Store the client socket
    {
        std::lock_guard<std::mutex> lock(m_clientMutex);
        m_clientSocket = clientSocket;
    }
    m_clientConnected.store(true);

    // Reset stats for new connection
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_bytesSent = 0;
        m_frameCount = 0;
        m_lastStatsTime = std::chrono::steady_clock::now();
    }

    // Send display config immediately upon connection
    sendDisplayConfig();

    // Notify connection callback
    if (m_connectionCallback) {
        m_connectionCallback(true);
    }

    // Start receive thread for touch events and ping/pong
    m_receiveThread = std::thread(&StreamingServer::receiveLoop, this);
}

// ============================================================================
// Receive loop (touch events, ping)
// ============================================================================

void StreamingServer::receiveLoop() {
    uint8_t msgType;

    while (m_running.load() && m_clientConnected.load()) {
        int sock;
        {
            std::lock_guard<std::mutex> lock(m_clientMutex);
            sock = m_clientSocket;
        }
        if (sock == -1) break;

        // Read message type (1 byte)
        if (!recvAll(sock, &msgType, 1)) {
            break; // Connection closed or error
        }

        if (msgType == Config::MSG_TOUCH_EVENT) {
            // Read pointer count (1 byte)
            uint8_t pointerCount;
            if (!recvAll(sock, &pointerCount, 1)) break;

            if (pointerCount < 1 || pointerCount > 2) {
                printf("[StreamingServer] Invalid pointer count: %d\n", pointerCount);
                break;
            }

            // Read coordinate floats + action
            // N pointers * 2 floats (x,y) * 4 bytes + 4 bytes action
            size_t coordSize = static_cast<size_t>(pointerCount) * 8; // N * (4B x + 4B y)
            size_t payloadSize = coordSize + 4; // + 4B action
            uint8_t payload[20]; // Max: 2 * 8 + 4 = 20 bytes

            if (!recvAll(sock, payload, payloadSize)) break;

            // Parse coordinates (Little-Endian floats)
            float x1 = readLEFloat(payload);
            float y1 = readLEFloat(payload + 4);
            float x2 = 0.0f;
            float y2 = 0.0f;

            if (pointerCount >= 2) {
                x2 = readLEFloat(payload + 8);
                y2 = readLEFloat(payload + 12);
            }

            // Parse action (Little-Endian int32)
            int32_t action = readLE32(payload + coordSize);

            // Invoke callback
            if (m_touchCallback) {
                m_touchCallback(static_cast<int>(pointerCount),
                               x1, y1, x2, y2,
                               static_cast<int>(action));
            }

        } else if (msgType == Config::MSG_PING) {
            // Read 8-byte timestamp (Little-Endian)
            uint8_t timestamp[8];
            if (!recvAll(sock, timestamp, 8)) break;

            // Echo back as pong
            sendPong(timestamp);

        } else {
            // Unknown message type - skip
            printf("[StreamingServer] Unknown message type: %d\n", msgType);
            // We cannot reliably recover from unknown messages since we don't
            // know their length, so disconnect
            break;
        }
    }

    // Client disconnected
    closeClient();

    if (m_connectionCallback) {
        m_connectionCallback(false);
    }

    printf("[StreamingServer] Client disconnected\n");
}

// ============================================================================
// Protocol: Display Config
// ============================================================================

void StreamingServer::sendDisplayConfig() {
    int sock;
    {
        std::lock_guard<std::mutex> lock(m_clientMutex);
        sock = m_clientSocket;
    }
    if (sock == -1) return;

    int width, height, rotation;
    {
        std::lock_guard<std::mutex> lock(m_displayMutex);
        width = m_displayWidth;
        height = m_displayHeight;
        rotation = m_rotation;
    }

    // [0x01][4B width BE][4B height BE][4B rotation BE] = 13 bytes
    uint8_t packet[13];
    packet[0] = Config::MSG_DISPLAY_CONFIG;
    writeBE32(packet + 1, static_cast<int32_t>(width));
    writeBE32(packet + 5, static_cast<int32_t>(height));
    writeBE32(packet + 9, static_cast<int32_t>(rotation));

    // Use sendMutex to avoid interleaving with frame sends
    std::lock_guard<std::mutex> lock(m_sendMutex);
    sendAll(sock, packet, sizeof(packet));

    printf("[StreamingServer] Sent display config: %dx%d @ %d deg\n",
           width, height, rotation);
}

// ============================================================================
// Protocol: Pong
// ============================================================================

void StreamingServer::sendPong(const uint8_t* timestampData) {
    int sock;
    {
        std::lock_guard<std::mutex> lock(m_clientMutex);
        sock = m_clientSocket;
    }
    if (sock == -1) return;

    // [0x05][8B timestamp LE echo] = 9 bytes
    uint8_t packet[9];
    packet[0] = Config::MSG_PONG;
    std::memcpy(packet + 1, timestampData, 8);

    std::lock_guard<std::mutex> lock(m_sendMutex);
    sendAll(sock, packet, sizeof(packet));
}

// ============================================================================
// Client management
// ============================================================================

void StreamingServer::closeClient() {
    m_clientConnected.store(false);

    std::lock_guard<std::mutex> lock(m_clientMutex);
    if (m_clientSocket != -1) {
        // Graceful shutdown: stop sends/receives, then close
        ::shutdown(m_clientSocket, SHUT_RDWR);
        ::close(m_clientSocket);
        m_clientSocket = -1;
    }
}

// ============================================================================
// Stats
// ============================================================================

void StreamingServer::updateStats(size_t bytes) {
    std::lock_guard<std::mutex> lock(m_statsMutex);

    m_bytesSent += bytes;
    m_frameCount++;

    auto now = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(now - m_lastStatsTime).count();

    if (elapsed >= 1.0) {
        double mbps = static_cast<double>(m_bytesSent * 8) / elapsed / 1'000'000.0;
        double fps = static_cast<double>(m_frameCount) / elapsed;

        if (m_statsCallback) {
            m_statsCallback(fps, mbps);
        }

        m_bytesSent = 0;
        m_frameCount = 0;
        m_lastStatsTime = now;
    }
}

// ============================================================================
// Socket helpers
// ============================================================================

bool StreamingServer::sendAll(int sock, const uint8_t* data, size_t size) {
    size_t totalSent = 0;
    while (totalSent < size) {
        ssize_t sent = ::send(sock, data + totalSent, size - totalSent, MSG_NOSIGNAL);
        if (sent <= 0) {
            return false;
        }
        totalSent += static_cast<size_t>(sent);
    }
    return true;
}

bool StreamingServer::recvAll(int sock, uint8_t* data, size_t size) {
    size_t totalRecv = 0;
    while (totalRecv < size) {
        ssize_t received = ::recv(sock, data + totalRecv, size - totalRecv, 0);
        if (received <= 0) {
            return false;
        }
        totalRecv += static_cast<size_t>(received);
    }
    return true;
}
